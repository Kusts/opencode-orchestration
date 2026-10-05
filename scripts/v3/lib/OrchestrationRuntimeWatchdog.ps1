<#!
.SYNOPSIS
    V3 Runtime Watchdog: shadow supervision + bounded ENFORCE path (P25/P26).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the watchdog
    from the V3.1 runtime-reliability addendum (SPEC Part A sections 4-7,
    PLAN Phase 25, SPEC section 15, PLAN Phase 26 tasks 1-10):

      - Register-OrchestrationWatchdogExecution: binds task_id + attempt_n
        + session_id + parent session + role + runtime/profile to a budget
        snapshot resolved through OrchestrationExecutionBudget (role or
        profile; explicit -Budget validated, never caller-widened here).
        Closed-charset id validation reused from the budget/kernel
        convention (lowercase [a-z0-9._-], 3-64 chars).
      - Optional OWN-process binding (Phase 26, hardened P26-FIX1):
        -ProcessId (+ optional -ProcessPath, -ParentProcessId,
        -ProcessStartTime) validated AT REGISTRATION time with EXACT
        creation-time identity (tick equality, no tolerance window) and
        PROVEN parentage (CIM must succeed and the live parent must be
        the current supervisor; declared values are never proof).
        CIM-unavailable/divergent/not-supervised registers WITHOUT a
        binding (advisory WATCHDOG_NO_PROCESS_IDENTITY). Registering
        WITHOUT a process binding under gate ENFORCE keeps the honest
        P25 HOLD (WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED, nothing stored):
        what cannot be owned cannot be safely interrupted.
      - Canonical action fingerprint: tool + normalized args + target +
        result class, each field sanitized INDIVIDUALLY before
        truncation and length-prefixed join (same redaction semantics
        as the Phase 21 baseline fixture: secret values and sk-
        canaries redacted, case-insensitive; value patterns never
        cross field boundaries, and the len:value framing keeps a
        literal '|' inside a field unambiguous, so the pair
        (Args='x|repo-a', Target='repo-b') never collides with
        (Args='x', Target='repo-a|repo-b')). Only the hex digest is
        ever stored or emitted; raw args never persist.
      - Progress classification with the SAME suffix-post-progress
        semantics as the baseline fixture: only the trailing run after the
        last meaningful progress is classified; old progress never masks a
        later stall. Thresholds (soft/hard/cycle) are read from the
        central policy file loop_guard at evaluation time, never literals.
      - Evaluation classes: HARD_TIMEOUT (wall clock), NO_PROGRESS
        (no_progress_seconds), REPEATED_ACTION soft (STALL_SUSPECTED) /
        hard, REPEATED_CYCLE (2-4 x3), BUDGET_NEAR_LIMIT (80% wall/steps,
        advisory only).
      - Shadow posture (enabled=false + shadow=true): emits sanitized
        telemetry events (STALL_SUSPECTED, WATCHDOG_WOULD_INTERRUPT +
        class, BUDGET_NEAR_LIMIT, NO_PROGRESS_SUSPECTED,
        REPEATED_ACTION_SUSPECTED) to a bounded JSONL file. NEVER
        interrupts a process/session, NEVER writes task records
        (read-only over tasks; the kernel is not even dot-sourced).
      - Enforce posture (Phase 26, hardened P26-FIX1 + P26-FIX2): executions bound
        to a verified OWN process follow the bounded interrupt path when
        the evaluation (same thresholds, same classes) returns an
        interrupting class (HARD_TIMEOUT, NO_PROGRESS, REPEATED_ACTION
        hard, REPEATED_CYCLE): ownership is re-verified (PID alive with
        proven-gone vs inspection-failure distinguished, executable path
        match, CIM-proven parent equal to the registered parent or the
        supervisor, EXACT creation-time tick equality) BEFORE any kill;
        any divergence or unverifiable fact returns
        WATCHDOG_INTERRUPT_REFUSED and nothing is killed (unknown PIDs
        are never killed). The kill runs on the PINNED handle of the
        VERIFIED instance (handle fixed at resolution on first access,
        never re-resolved by PID for pre-check, Kill or WaitForExit;
        every non-transferred handle closed deterministically via the
        disposal choke point) and covers the verified
        descendant tree (CIM snapshot descent carrying pid+ticks
        identity, two-phase: verify all before killing any; a candidate
        clearly older than its ancestor is proof of NON-descendence and
        is EXCLUDED from the kill set, transitively, counted in
        tree_excluded (with the WATCHDOG_TREE_EXCLUDED token on
        success); ambiguous lineage, depth/node caps
        (WATCHDOG_TREE_LIMIT_EXCEEDED) or the shared preparation
        deadline fail closed with nothing killed; the deadline is
        re-checked after every enumeration/query call, at every
        candidate, and immediately before the first kill in BOTH
        paths (late breach => WATCHDOG_DEADLINE_EXCEEDED); the gone
        path attributes descendants to the registered generation
        ONLY (exact identities from the last verified set, or
        creations not newer than lastAliveProof, else EXCLUDED); the normal
        path additionally attaches the verified root to an anonymous
        Job Object before the snapshot (RR-P26-JOB-WIRING) so that
        post-attach spawns, invisible to the CIM walk, are covered by
        the job backstop; the attach is fail-closed and a refusal runs
        the CIM-only path unchanged. When the root already left (gone at ownership, or
        between ownership and stop) the verified descendant set is
        still liquidated and ALREADY_EXITED is returned only after the
        whole set exits, else WATCHDOG_INTERRUPT_FAILED with settlement
        PENDING. Stop failure returns
        WATCHDOG_INTERRUPT_FAILED (structured, no throw, no retry loop).
        After the kill, exit is confirmed on the held handles with a
        shared bounded wait against the shared enforce deadline and a
        settlement event is recorded
        (WATCHDOG_INTERRUPTED + WATCHDOG_SETTLED, ALREADY_EXITED when the
        set left on its own, PENDING when exit cannot be confirmed,
        STILL_RUNNING when the tree survives the bound). Terminal
        settlements (SETTLED/ALREADY_EXITED) are sticky and idempotent
        by ANY entry (central guard, never degraded). Executions
        WITHOUT a process binding stay advisory-only under ENFORCE
        (WATCHDOG_NO_PROCESS_IDENTITY): nothing is killed.
        Enforcement results reference the evaluation snapshot + the
        telemetry FILE (never its content), preserving partial evidence.
        Settlement is queryable via Get-OrchestrationWatchdogSettlement
        (or Get-OrchestrationWatchdogEvaluation -IncludeEnforcement).
      - Flag seam (read-only): watchdog{enabled,shadow} from -FlagsPath
        (default source/registry/capability-flags.json). enabled=false +
        shadow=false (or node missing) => WATCHDOG_DISABLED, no effect.
        enabled=false + shadow=true => shadow telemetry only.
        This file never writes flags.
      - Cross-process telemetry write coordination: the pre-size
        accounting + append runs under a NAMED kernel mutex whose name
        is deterministic from the CANONICAL telemetry directory
        ([IO.Path]::GetFullPath + [IO.DirectoryInfo].FullName, folded
        to lower case, sha256 hash16), so every writer in every process
        that spells the same directory differently - relative or
        absolute, trailing separator, '.\' suffix, internal '..\',
        other case - coordinates on the same object (the in-process
        Monitor alone only covered one writer per process). The wait is
        BOUNDED ($script:WatchdogTelemetryMutexWaitMs, default 300 ms)
        and telemetry is best-effort observability: contention SKIPS the
        write with an honest reason ('lock-busy'), never blocking the
        caller path. An ABANDONED mutex (holder died mid-append) is
        fail-safe too: AbandonedMutexException is caught, ownership
        released at once and the write SKIPPED ('mutex-abandoned'). An
        unopenable mutex also skips ('mutex-unavailable'); the writer
        never throws and never writes uncoordinated.
        KNOWN LIMITATION (best-effort, documented on purpose): the gate
        is a NAME, so a hostile process may squat it and hold it. Every
        event then pays one bounded 300 ms wait and is dropped
        ('lock-busy'), and an abandoned name is not even signalled when
        no other handle keeps the object alive. Therefore watchdog
        telemetry is ADVISORY ONLY: missing events (or a whole missing
        day) are acceptable, and telemetry MUST NEVER be used as
        mandatory proof of execution, authorization or settlement -
        under the Evidence Contract a verified_pass comes only from the
        kernel / an allowlisted verifier, never from this file.
      - Framing guard for the same file: before every append, under the
        gate, Test-WatchdogTelemetryTailIntact requires the file to end
        with a complete LF-terminated JSON line (bounded 8 KB tail
        read); otherwise the event is refused ('tail-incomplete' /
        'tail-unreadable') and the fragment is preserved as evidence.
        Losing one event is acceptable, corrupting the JSONL is not.
      - Bounded multi-day retention of the same telemetry (the P25
        follow-up): one operation resolves the telemetry directory
        EXACTLY ONCE and pins that absolute value for target, gate and
        sweep (a relative root must never be re-resolved later against
        the process working directory). Invoke-WatchdogTelemetryRetention
        sweeps ONLY files
        whose name matches the watchdog daily pattern
        (watchdog-YYYYMMDD.jsonl) in the resolved telemetry directory
        and deletes the ones whose stamp is strictly older than the
        horizon ($script:WatchdogTelemetryRetentionDays, default 7
        days: today plus the horizon are always kept), refusing the
        sweep entirely when the telemetry directory is itself a reparse
        point ('reparse-detected'). Caps bound the work per call
        ($script:WatchdogRetentionMaxExamined, default 64 ENTRIES
        examined, spent per file system entry visited - names outside
        the pattern and subdirectories included - by incremental
        enumeration; 0 means 'examine nothing', returned before any
        enumeration; $script:WatchdogRetentionMaxDeleted, default 32
        deleted), the clock is injectable (-AtUtc) for determinism, and
        a per-file delete failure leaves that file in place and
        continues the sweep. Anything not matching the pattern, and any
        directory, is never touched. Deletion covers the oldest files
        WITHIN THE EXAMINED BATCH and reports 'truncated' conservatively
        from the counter (no probe). Retention runs best-effort after a
        successful telemetry write (the write result is never changed by
        it).
        ACCEPTED RESIDUAL - retention has NO cross-call cursor: a
        non-deletable prefix (in-horizon files, files owned by someone
        else, hostile names) can consume the whole budget on every call
        and starve the entries behind it. This is best-effort cleanup of
        a shadow-path directory controlled by the kernel, so a cursor is
        out of scope on purpose; the starvation is at least OBSERVABLE
        (no_progress / 'no-progress' when truncated with nothing
        deleted) instead of silent. A cursor becomes a follow-up only if
        enforcement is ever activated. As everywhere else here, telemetry
        is never proof of execution or authorization.
      - Bounded: per-execution fingerprint history capped at 256 entries
        (oldest evicted, counter kept); telemetry file rotation cap
        (1 MB per daily file, check+append under the exclusive
        in-process lock AND the cross-process named mutex,
        fail-closed: accounting failure or overflow refuses the write);
        clock is UTC (Get-Date).ToUniversalTime() unless -AtUtc
        overrides (tests); settlement wait bounded (30 x 100ms); no
        infinite waits anywhere.

    PowerShell 5.1 compatible. ASCII-only. Expected domain errors are
    returned as result objects ({ok:$false, error:'CODE'}), never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$watchdogBudgetPath = Join-Path $PSScriptRoot 'OrchestrationExecutionBudget.ps1'
if (Test-Path -LiteralPath $watchdogBudgetPath -PathType Leaf) {
    . $watchdogBudgetPath
}
$watchdogObservabilityPath = Join-Path $PSScriptRoot 'CapabilityObservability.ps1'
if (Test-Path -LiteralPath $watchdogObservabilityPath -PathType Leaf) {
    . $watchdogObservabilityPath
}
# RR-P26-JOB-WIRING: backstop de Job Object no enforcement (opcional, mesmo
# padrao das libs acima). Ausente => job_backstop indisponivel e o caminho
# CIM-ONLY de hoje roda identico, com a nota 'refused:job-lib-unavailable'.
$watchdogJobObjectPath = Join-Path $PSScriptRoot '..\..\runtime\lib\RuntimeJobObject.ps1'
$script:WatchdogJobLibReady = $false
if (Test-Path -LiteralPath $watchdogJobObjectPath -PathType Leaf) {
    . $watchdogJobObjectPath
    $script:WatchdogJobLibReady = [bool]((Get-Command New-RuntimeJobObject -ErrorAction SilentlyContinue) -ne $null)
}

$script:WatchdogExecutions = @{}
$script:WatchdogHistoryCap = 256
$script:WatchdogTelemetryCapBytes = 1048576
$script:WatchdogNearLimitRatio = 0.8
$script:WatchdogTelemetryLock = New-Object Object
$script:WatchdogTelemetryMutexWaitMs = 300
$script:WatchdogTelemetryRetentionDays = 7
$script:WatchdogRetentionMaxExamined = 64
$script:WatchdogRetentionMaxDeleted = 32
$script:WatchdogSimulateAccountingFailure = $false

# ---------- repo / path helpers ----------

function Get-WatchdogRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-WatchdogDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-WatchdogRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\execution-budget-policy.json')
}

function Get-WatchdogDefaultFlagsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-WatchdogRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-flags.json')
}

function New-WatchdogError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code, $Extra)
    $r = [ordered]@{ ok = $false; error = $Code }
    if ($null -ne $Extra) {
        if ($Extra -is [System.Collections.IDictionary]) {
            foreach ($k in @($Extra.Keys)) { $r[[string]$k] = $Extra[$k] }
        }
        else {
            foreach ($p in @($Extra.PSObject.Properties)) { $r[$p.Name] = $p.Value }
        }
    }
    return ([PSCustomObject]$r)
}

# ---------- closed validation (budget/kernel convention) ----------

function Test-WatchdogId {
    <#
    .SYNOPSIS
        Closed-charset identity: lowercase alnum start, 3-64 chars of
        [a-z0-9._-]. Same convention as Test-TaskKernelId /
        Test-ExecutionBudgetEventId. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Test-WatchdogAttemptN {
    <#
    .SYNOPSIS
        Strict attempt number: [int]/[long] in [1, 1000000]. Rejects
        bool/string/double. Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]))) { return $false }
        $n = [long]$Value
        return (($n -ge 1) -and ($n -le 1000000))
    }
    catch { return $false }
}

function Get-WatchdogUtcNow {
    <#
    .SYNOPSIS
        UTC clock. -AtUtc (DateTime or ISO string) overrides for tests.
        Never throws; falls back to real UTC now.
    #>
    [CmdletBinding()]
    param($AtUtc)
    try {
        if ($null -ne $AtUtc) {
            if ($AtUtc -is [DateTime]) { return ([DateTime]$AtUtc).ToUniversalTime() }
            $s = ([string]$AtUtc).Trim()
            if (-not [string]::IsNullOrWhiteSpace($s)) {
                $dto = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($s, [ref]$dto)) { return $dto.UtcDateTime }
            }
        }
    }
    catch { }
    try { return ((Get-Date).ToUniversalTime()) }
    catch { return ([DateTime]::UtcNow) }
}

# ---------- flag seam (read-only) ----------

function Get-WatchdogFlagState {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $out = @{ enabled = $false; shadow = $false }
    try {
        $p = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-WatchdogDefaultFlagsPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        if ($null -eq $doc) { return $out }
        $node = $null
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('watchdog')) { $node = $doc['watchdog'] }
        }
        else {
            $prop = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'watchdog' } | Select-Object -First 1
            if ($null -ne $prop) { $node = $prop.Value }
        }
        if ($null -eq $node) { return $out }
        foreach ($field in @('enabled', 'shadow')) {
            $slot = $null
            if ($node -is [System.Collections.IDictionary]) {
                if ($node.Contains($field)) { $slot = $node[$field] }
            }
            else {
                $fp = $node.PSObject.Properties | Where-Object { $_.Name -ceq $field } | Select-Object -First 1
                if ($null -ne $fp) { $slot = $fp.Value }
            }
            if (($null -ne $slot) -and ($slot -is [bool])) {
                if ($field -ceq 'enabled') { $out.enabled = [bool]$slot }
                else { $out.shadow = [bool]$slot }
            }
        }
    }
    catch { return $out }
    return $out
}

function Get-WatchdogGate {
    <#
    .SYNOPSIS
        Resolves the flag seam: ENFORCE (honest not-implemented) when
        enabled=true; SHADOW when enabled=false + shadow=true; DISABLED
        otherwise. Never throws.
    #>
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    try {
        $f = Get-WatchdogFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ([bool]$f.enabled) { return 'ENFORCE' }
        if ([bool]$f.shadow) { return 'SHADOW' }
        return 'DISABLED'
    }
    catch { return 'DISABLED' }
}

# ---------- loop limits (from central policy, never literals) ----------

function Get-WatchdogLoopLimits {
    <#
    .SYNOPSIS
        Reads loop_guard (soft/hard/cycle) from the central policy file
        via the budget lib. Returns ok + limits or LIMITS_UNAVAILABLE /
        BUDGET_LIB_UNAVAILABLE / BUDGET_POLICY_INVALID. Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    try {
        if ((Get-Command Read-ExecutionBudgetPolicy -ErrorAction SilentlyContinue) -eq $null) {
            return (New-WatchdogError -Code 'BUDGET_LIB_UNAVAILABLE')
        }
        $slot = Read-ExecutionBudgetPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$slot.found) { return (New-WatchdogError -Code 'BUDGET_POLICY_UNAVAILABLE') }
        if ([bool]$slot.malformed) { return (New-WatchdogError -Code 'BUDGET_POLICY_INVALID') }
        $guard = Get-ExecutionBudgetPolicyNode -Doc $slot.doc -Name 'loop_guard'
        if (($null -eq $guard) -or -not ($guard -is [System.Collections.IDictionary])) {
            return (New-WatchdogError -Code 'BUDGET_POLICY_INVALID')
        }
        $vals = @{}
        foreach ($gf in @('repeated_action_soft_limit', 'repeated_action_hard_limit', 'cycle_repeat_limit')) {
            $gv = $null
            if ($guard.Contains($gf)) { $gv = $guard[$gf] }
            if (-not (Test-ExecutionBudgetInt -Value $gv -Min 1 -Max 100)) {
                return (New-WatchdogError -Code 'BUDGET_POLICY_INVALID')
            }
            $vals[$gf] = [int]$gv
        }
        if ([int]$vals['repeated_action_soft_limit'] -ge [int]$vals['repeated_action_hard_limit']) {
            return (New-WatchdogError -Code 'BUDGET_POLICY_INVALID')
        }
        return [PSCustomObject]@{
            ok   = $true
            soft = [int]$vals['repeated_action_soft_limit']
            hard = [int]$vals['repeated_action_hard_limit']
            cycle = [int]$vals['cycle_repeat_limit']
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}

# ---------- canonical fingerprint (sanitized per-field before hash) ----------

function Get-WatchdogFieldRedaction {
    <#
    .SYNOPSIS
        Redacts one fingerprint field (same semantics as the Phase 21
        baseline fixture: secret values and sk- canaries redacted,
        case-insensitive). Applied per-field BEFORE truncation and join,
        so patterns never see the '|' separators. Value patterns use
        [^\s|]+ (never cross a separator) instead of \S+. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = ([string]$Value)
        $s = $s -replace '(?i)JEV_API_KEY\s*[=:\s]+[^\s|]+', 'JEV_API_KEY <redacted>'
        $s = $s -replace '(?i)(token|api[_-]?key|secret|password)\s*=\s*[^\s|]+', '$1=<redacted>'
        $s = $s -replace '(?i)sk-[A-Za-z0-9\-_]+', '<redacted>'
        try {
            if ((Get-Command Get-SecretValuePattern -ErrorAction SilentlyContinue) -ne $null) {
                $pat = (Get-SecretValuePattern)
                if (-not [string]::IsNullOrWhiteSpace([string]$pat)) {
                    $s = ([regex]::Replace($s, [string]$pat, '[REDACTED]'))
                }
            }
        }
        catch { }
        return $s
    }
    catch { return ([string]$Value) }
}

function Get-WatchdogActionFingerprint {
    <#
    .SYNOPSIS
        Canonical sha256 fingerprint of tool + normalized args + target +
        result class. Each field is normalized, redacted (per-field, via
        Get-WatchdogFieldRedaction) and size-capped INDIVIDUALLY, then
        framed as len:value (length in chars of the sanitized field)
        and joined with '|'; no post-join redaction runs, so a secret
        value can never consume separators and bleed into target/result
        class (distinct targets/classes keep distinct digests while
        distinct secrets converge), and a literal '|' inside a field
        can never shift field boundaries (length prefix disambiguates).
        Only the hex digest is returned; raw args never leave this
        function. Returns '' on invalid input. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Tool, [string]$Arguments, [string]$Target, [string]$ResultClass)
    try {
        $t = ([string]$Tool).Trim().ToLowerInvariant() -replace '\s+', ' '
        if ([string]::IsNullOrWhiteSpace($t)) { return '' }
        $t = Get-WatchdogFieldRedaction -Value $t
        if ($t.Length -gt 64) { $t = $t.Substring(0, 64) }
        $a = ([string]$Arguments).Trim() -replace '\s+', ' '
        $a = Get-WatchdogFieldRedaction -Value $a
        if ($a.Length -gt 500) { $a = $a.Substring(0, 500) }
        $r = ([string]$Target).Trim().ToLowerInvariant() -replace '\\', '/'
        $r = Get-WatchdogFieldRedaction -Value $r
        if ($r.Length -gt 256) { $r = $r.Substring(0, 256) }
        $c = ([string]$ResultClass).Trim().ToLowerInvariant() -replace '\s+', ' '
        $c = Get-WatchdogFieldRedaction -Value $c
        if ($c.Length -gt 64) { $c = $c.Substring(0, 64) }
        $joined = ([string]$t.Length) + ':' + $t + '|' + ([string]$a.Length) + ':' + $a + '|' + ([string]$r.Length) + ':' + $r + '|' + ([string]$c.Length) + ':' + $c
        if ($joined.Length -gt 1024) { $joined = $joined.Substring(0, 1024) }
        $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) }
        finally { try { $sha.Dispose() } catch { } }
        return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
    }
    catch { return '' }
}

function Test-WatchdogRepetitionClass {
    <#
    .SYNOPSIS
        Classifies the trailing no-progress suffix (same semantics as the
        Phase 21 baseline fixture): discards everything up to and
        including the last meaningful progress, then checks the identical
        trailing run (soft => STALL_SUSPECTED, hard => HARD_STALL) and
        short cycles of length 2-4 repeated 3x (=> REPEATED_CYCLE).
        Limits come from the caller (policy), never literals here.
        Returns NONE | STALL_SUSPECTED | HARD_STALL | REPEATED_CYCLE.
        Never throws.
    #>
    [CmdletBinding()]
    param([string[]]$Fingerprints, [bool[]]$ProgressFlags, [int]$SoftLimit = 3, [int]$HardLimit = 5, [int]$CycleLimit = 3)
    try {
        $fps = @($Fingerprints)
        if ($fps.Count -eq 0) { return 'NONE' }
        $soft = [int]$SoftLimit
        $hard = [int]$HardLimit
        $cycLim = [int]$CycleLimit
        if ($soft -lt 1) { $soft = 3 }
        if ($hard -le $soft) { $hard = ($soft + 2) }
        if ($cycLim -lt 1) { $cycLim = 3 }
        $n = $fps.Count
        $m = @($ProgressFlags).Count
        $cut = 0
        for ($k = 0; $k -lt $n; $k++) {
            if (($k -lt $m) -and ([bool]$ProgressFlags[$k])) { $cut = ($k + 1) }
        }
        $s = ($n - $cut)
        if ($s -le 0) { return 'NONE' }
        $run = 1
        for ($i = ($n - 1); $i -gt $cut; $i--) {
            if ([string]$fps[$i] -ceq [string]$fps[($i - 1)]) { $run++ }
            else { break }
        }
        if ($run -ge $hard) { return 'HARD_STALL' }
        if ($run -ge $soft) { return 'STALL_SUSPECTED' }
        foreach ($len in @(2, 3, 4)) {
            $need = ($len * $cycLim)
            if ($s -lt $need) { continue }
            $tail = @($fps[(($n - $need))..(($n - 1))])
            $okCycle = $true
            $first = (($tail[0..(($len - 1))] -join ','))
            for ($rep = 1; $rep -lt $cycLim; $rep++) {
                $lo = ($rep * $len)
                $hi = (($rep * $len) + $len - 1)
                $block = (($tail[$lo..$hi] -join ','))
                if ($block -cne $first) { $okCycle = $false; break }
            }
            if ($okCycle) { return 'REPEATED_CYCLE' }
        }
        return 'NONE'
    }
    catch { return 'NONE' }
}

# ---------- shadow telemetry (sanitized, bounded, never blocks) ----------

function Get-WatchdogTaskHash16 {
    [CmdletBinding()]
    param([string]$TaskId)
    try {
        if ((Get-Command Get-ObservabilityTaskKeyHex -ErrorAction SilentlyContinue) -ne $null) {
            $h = (Get-ObservabilityTaskKeyHex -TaskId ([string]$TaskId))
            if (-not [string]::IsNullOrWhiteSpace([string]$h)) { return ([string]$h).ToLowerInvariant() }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(([string]$TaskId).Trim())
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) }
        finally { try { $sha.Dispose() } catch { } }
        $hex = ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
        return $hex.Substring(0, 16)
    }
    catch { return 'unavailable' }
}

function Resolve-WatchdogCanonicalDirectoryPath {
    <#
    .SYNOPSIS
        Canonical ABSOLUTE directory path (shared by the writer, the
        cross-process mutex name and retention, so all three agree on
        one identity for "the same directory"): [IO.Path]::GetFullPath
        (collapses '.', '..' and relative segments) followed by
        [IO.DirectoryInfo].FullName (canonical rooted form, no trailing
        separator). A relative path resolves against the PROCESS working
        directory ([Environment]::CurrentDirectory), deliberately NOT the
        PowerShell location: a per-runspace location would make the same
        call resolve differently depending on the caller's session,
        while the process directory is the stable base two producers
        writing the same relative path already agree on. Case is folded
        later by the mutex name, so the common spellings of one Windows
        path - different case, trailing separator, '.\' suffix,
        internal '..\', relative vs absolute - produce the SAME mutex and
        the SAME sweep target. Returns '' when no canonical form can be
        derived (callers
        fail safe: skip the write / refuse the sweep, never act on a
        half-resolved path).
        LIMITATION (accepted residual): junction/symlink/subst ALIASES
        are NOT resolved to a common target - a path reached through an
        alias gets that alias' identity. Only the trusted caller chooses
        the telemetry root, so this cannot redirect one writer's data
        into another's gate.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$Path)
    try {
        $p = ([string]$Path).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { return '' }
        $full = [IO.Path]::GetFullPath($p)
        if ([string]::IsNullOrWhiteSpace([string]$full)) { return '' }
        $info = [IO.DirectoryInfo]::new([string]$full)
        return ([string]$info.FullName)
    }
    catch { return '' }
}

function Get-WatchdogTelemetryDirectory {
    <#
    .SYNOPSIS
        Single CANONICAL resolution of the telemetry DIRECTORY:
        -TelemetryRoot when given, else <repo>\cache\v3\telemetry,
        passed through Resolve-WatchdogCanonicalDirectoryPath. Shared by
        the daily file name, the cross-process mutex name and retention,
        so the writer, the gate and the sweep always agree on one
        directory identity (one mutex, one cap, one sweep target).
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot)
    try {
        $dir = $TelemetryRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $repo = Get-WatchdogRepoRoot -RepoRoot $RepoRoot
            $dir = Join-Path $repo 'cache\v3\telemetry'
        }
        return (Resolve-WatchdogCanonicalDirectoryPath -Path ([string]$dir))
    }
    catch { return '' }
}

function Test-WatchdogTelemetryDirectoryReparse {
    <#
    .SYNOPSIS
        Guard for the retention sweep: the telemetry directory ITSELF
        must not be a reparse point (junction/symlink/mount point).
        A junction would silently redirect deletion outside the physical
        directory the caller believes it owns, so the sweep is REFUSED
        fail-safe (delete nothing, structured reason) instead of
        traversing it. A plain missing/unreadable directory is reported
        too, but as its own reason.
        ACCEPTED RESIDUAL (same judgement as the security review): a
        reparse point in an ANCESTOR of the telemetry root is not
        resolved or refused - the trusted caller owns the root it hands
        in, and a per-directory check here cannot prove anything about
        ancestors without walking the whole volume. Returns
        @{ok; reason} where reason is '' | 'no-directory' |
        'attributes-unavailable' | 'reparse-detected'. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Directory)
    try {
        $dir = ([string]$Directory).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) { return [PSCustomObject]@{ ok = $false; reason = 'no-directory' } }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return [PSCustomObject]@{ ok = $false; reason = 'no-directory' } }
        $attrs = 0
        try { $attrs = [int][IO.File]::GetAttributes($dir) }
        catch { return [PSCustomObject]@{ ok = $false; reason = 'attributes-unavailable' } }
        if (($attrs -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [PSCustomObject]@{ ok = $false; reason = 'reparse-detected' }
        }
        return [PSCustomObject]@{ ok = $true; reason = '' }
    }
    catch { return [PSCustomObject]@{ ok = $false; reason = 'attributes-unavailable' } }
}

function Get-WatchdogTelemetryFile {
    <#
    .SYNOPSIS
        Daily file name (watchdog-YYYYMMDD.jsonl) inside a telemetry
        directory. -Directory, when given, is used AS IS: it is the
        already-resolved canonical value the caller pinned for this
        operation, and re-resolving it would re-introduce the
        working-directory dependency the pinning exists to remove (see
        Resolve-WatchdogCanonicalDirectoryPath and the single-resolution
        rule in Write-WatchdogTelemetryEvent). Without -Directory the
        directory is resolved from -TelemetryRoot/-RepoRoot.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot, [string]$Directory = '')
    try {
        $dir = ([string]$Directory).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = Get-WatchdogTelemetryDirectory -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        }
        if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $dir ('watchdog-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Get-WatchdogTelemetryMutexName {
    <#
    .SYNOPSIS
        Deterministic CROSS-PROCESS gate name for a telemetry directory:
        'Global\OrchWatchdogTel-<sha256 hash16>' over the CANONICAL
        directory path (Resolve-WatchdogCanonicalDirectoryPath:
        [IO.Path]::GetFullPath + [IO.DirectoryInfo].FullName) folded to
        invariant lower case. Every common spelling of one Windows path -
        different case, trailing separator, '.\' suffix, internal '..\',
        relative vs absolute - therefore derives the SAME name, so the
        exclusivity of the rotation cap really is cross-process for the
        same directory. LIMITATION: junction/symlink/subst aliases are
        NOT resolved (see Resolve-WatchdogCanonicalDirectoryPath).
        -Directory wins over -TelemetryRoot/-RepoRoot. Returns '' when no
        name can be derived (callers then skip the write: fail-safe,
        never uncoordinated). Never throws.
    #>
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot, [string]$Directory = '')
    try {
        $dir = ([string]$Directory).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = Get-WatchdogTelemetryDirectory -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        }
        else { $dir = Resolve-WatchdogCanonicalDirectoryPath -Path $dir }
        if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
        $norm = ($dir -replace '/', '\').TrimEnd('\').ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($norm)) { return '' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) }
        finally { try { $sha.Dispose() } catch { } }
        $hex = ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant()).Substring(0, 16)
        return ('Global\OrchWatchdogTel-' + $hex)
    }
    catch { return '' }
}

function Enter-WatchdogTelemetryWriteGate {
    <#
    .SYNOPSIS
        Cross-process write gate for the daily watchdog JSONL. Opens the
        named mutex derived from the telemetry directory and acquires it
        with a BOUNDED wait ($script:WatchdogTelemetryMutexWaitMs,
        default 300 ms): telemetry is best-effort observability, so
        contention SKIPS the write with an honest reason instead of
        blocking the caller path (lock-busy). Abandonment by a holder
        that died mid-append is fail-safe: AbandonedMutexException is
        caught, the ownership it grants is released immediately and the
        write is SKIPPED (mutex-abandoned), so no line is ever appended
        after a possibly truncated one. A mutex that cannot be opened at
        all also skips (mutex-unavailable; Global namespace first,
        session Local namespace as fallback). Returns
        @{ok; skipped; mutex; owned} - the caller releases ownership and
        disposes the handle. Never throws.
    #>
    [CmdletBinding()]
    param([string]$TelemetryFile = '', [string]$TelemetryRoot = '', [string]$RepoRoot = '')
    $mutex = $null
    try {
        $dir = ''
        try { $dir = ([string](Split-Path -Parent ([string]$TelemetryFile))).Trim() } catch { $dir = '' }
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = Get-WatchdogTelemetryDirectory -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        }
        $name = Get-WatchdogTelemetryMutexName -Directory $dir
        if ([string]::IsNullOrWhiteSpace($name)) {
            return [PSCustomObject]@{ ok = $false; skipped = 'mutex-unavailable'; mutex = $null; owned = $false }
        }
        $waitMs = 300
        try { $waitMs = [int]$script:WatchdogTelemetryMutexWaitMs } catch { $waitMs = 300 }
        if ($waitMs -lt 0) { $waitMs = 0 }
        if ($waitMs -gt 10000) { $waitMs = 10000 }
        $candidates = @($name)
        if ($name.StartsWith('Global\')) { $candidates += ('Local\' + $name.Substring(7)) }
        else { $candidates += ('Global\' + $name) }
        foreach ($cand in @($candidates)) {
            $m = $null
            try { $m = [System.Threading.Mutex]::new($false, [string]$cand) }
            catch { try { if ($null -ne $m) { $m.Dispose() } } catch { }; $m = $null }
            if ($null -eq $m) { continue }
            $took = $false
            $abandoned = $false
            try { $took = [bool]$m.WaitOne([int]$waitMs) }
            catch [System.Threading.AbandonedMutexException] { $abandoned = $true; $took = $true }
            catch { $took = $false }
            if ([bool]$abandoned) {
                try { $m.ReleaseMutex() } catch { }
                try { $m.Dispose() } catch { }
                return [PSCustomObject]@{ ok = $false; skipped = 'mutex-abandoned'; mutex = $null; owned = $false }
            }
            if (-not [bool]$took) {
                try { $m.Dispose() } catch { }
                return [PSCustomObject]@{ ok = $false; skipped = 'lock-busy'; mutex = $null; owned = $false }
            }
            $mutex = $m
            return [PSCustomObject]@{ ok = $true; skipped = ''; mutex = $m; owned = $true }
        }
        return [PSCustomObject]@{ ok = $false; skipped = 'mutex-unavailable'; mutex = $null; owned = $false }
    }
    catch {
        try { if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { }; try { $mutex.Dispose() } catch { } } } catch { }
        return [PSCustomObject]@{ ok = $false; skipped = 'mutex-unavailable'; mutex = $null; owned = $false }
    }
}

function Exit-WatchdogTelemetryWriteGate {
    <#
    .SYNOPSIS
        Deterministic release choke point for the cross-process gate:
        releases ownership (only when acquired) and disposes the handle,
        exactly once per successful acquisition, on every exit path.
        Never throws.
    #>
    [CmdletBinding()]
    param($Mutex, [bool]$Owned = $false)
    try {
        if ($null -ne $Mutex) {
            if ([bool]$Owned) { try { $Mutex.ReleaseMutex() } catch { } }
            try { $Mutex.Dispose() } catch { }
        }
    }
    catch { }
}

function Invoke-WatchdogTelemetryRetention {
    <#
    .SYNOPSIS
        Bounded multi-day retention of the watchdog telemetry (P25
        follow-up). -Directory, when given, is the ALREADY-RESOLVED
        canonical directory pinned by the caller for this operation and
        is used as is (FIX8: the writer resolves once and passes that
        value, so a working-directory change during the operation can
        never redirect the sweep); without it the directory is resolved
        from -TelemetryRoot/-RepoRoot. Sweeps
        the resolved telemetry directory and deletes
        ONLY files whose name matches the daily watchdog pattern
        (watchdog-YYYYMMDD.jsonl, strict case-sensitive pattern with a
        valid calendar stamp) whose stamp is strictly older than the
        horizon ($script:WatchdogTelemetryRetentionDays, default 7
        days: today plus the horizon are always kept). Anything else in
        the directory - other producers, other extensions, malformed
        stamps - is never touched, and the directory ITSELF must not be
        a reparse point (junction/symlink): such a directory is refused
        fail-safe with reason 'reparse-detected' and nothing is deleted
        (a reparse point in an ANCESTOR is an accepted residual: the
        trusted caller owns the root it hands in - see
        Test-WatchdogTelemetryDirectoryReparse). Work is bounded per call by
        -MaxFilesExamined (default $script:WatchdogRetentionMaxExamined,
        64) and -MaxFilesDeleted (default
        $script:WatchdogRetentionMaxDeleted, 32), spent by INCREMENTAL
        enumeration of EVERY file system entry
        ([IO.Directory]::EnumerateFileSystemEntries, NO glob): each entry
        visited costs budget BEFORE any validation, whatever it is - a
        non-matching name, a subdirectory, a telemetry-looking directory
        - so a directory flooded by an untrusted writer cannot make one
        append materialize, validate and sort an unbounded list, and no
        entry is ever scanned for free outside the declared budget. Only
        the limited batch is ordered, so deletion targets the OLDEST
        files WITHIN THE EXAMINED BATCH - not a claimed global oldest,
        which would require scanning everything. 'truncated' is reported
        CONSERVATIVELY as (examined == max examined) with NO probe (a
        probe would visit one entry outside the budget), so a directory
        holding exactly as many entries as the cap reports truncated
        even when nothing was left behind. An examined cap of 0 returns
        'cap-zero' BEFORE any enumerator is created, so nothing is even
        listed. The clock is injectable
        (-AtUtc, DateTime or ISO string) for deterministic tests. A
        per-file delete failure leaves that file in place and CONTINUES
        the sweep (counted in failed); the result is advisory telemetry
        bookkeeping and never throws. Only files of OTHER days are
        deleted, never the file the current process appends to, and
        never a directory.
        STARVATION SIGNAL (no cursor by design): there is no cross-call
        cursor, so a non-deletable prefix can consume the whole budget on
        every call. When that happens the result says so explicitly -
        no_progress=$true with reason='no-progress' (truncated with
        nothing deleted) - instead of looking like a healthy sweep.
        Returns @{ok; examined; deleted; retained; failed; truncated;
        no_progress; retention_days; max_examined; max_deleted; reason}.
    #>
    [CmdletBinding()]
    param(
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        $AtUtc = $null,
        [int]$RetentionDays = -1,
        [int]$MaxFilesExamined = -1,
        [int]$MaxFilesDeleted = -1,
        [string]$Directory = ''
    )
    $days = 7
    $maxExam = 64
    $maxDel = 32
    try {
        try { $days = [int]$script:WatchdogTelemetryRetentionDays } catch { $days = 7 }
        if ($RetentionDays -ge 0) { $days = [int]$RetentionDays }
        if ($days -lt 1) { $days = 1 }
        if ($days -gt 3650) { $days = 3650 }
        try { $maxExam = [int]$script:WatchdogRetentionMaxExamined } catch { $maxExam = 64 }
        if ($MaxFilesExamined -ge 0) { $maxExam = [int]$MaxFilesExamined }
        if ($maxExam -lt 0) { $maxExam = 0 }
        if ($maxExam -gt 4096) { $maxExam = 4096 }
        try { $maxDel = [int]$script:WatchdogRetentionMaxDeleted } catch { $maxDel = 32 }
        if ($MaxFilesDeleted -ge 0) { $maxDel = [int]$MaxFilesDeleted }
        if ($maxDel -lt 0) { $maxDel = 0 }
        if ($maxDel -gt 4096) { $maxDel = 4096 }
        $res = [ordered]@{
            ok             = $true
            examined       = 0
            deleted        = 0
            retained       = 0
            failed         = 0
            truncated      = $false
            no_progress    = $false
            retention_days = [int]$days
            max_examined   = [int]$maxExam
            max_deleted    = [int]$maxDel
            reason         = ''
        }
        # FIX8: -Directory carries the ALREADY-RESOLVED canonical directory
        # pinned by the caller for this operation and is used as is.
        # Re-resolving a relative -TelemetryRoot here would resolve it
        # against [Environment]::CurrentDirectory AGAIN, and that value is
        # process-wide mutable: a working-directory change between the
        # writer's target resolution and this sweep could then delete old
        # telemetry in a DIFFERENT directory than the one just written.
        $dir = ([string]$Directory).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dir = Get-WatchdogTelemetryDirectory -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        }
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $res['ok'] = $false
            $res['reason'] = 'no-directory'
            return [PSCustomObject]$res
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            $res['reason'] = 'no-directory'
            return [PSCustomObject]$res
        }
        # F4: never sweep THROUGH a reparse point. A junction used AS the
        # telemetry directory would redirect deletion outside the physical
        # directory the caller believes it owns, so the whole sweep is
        # refused (nothing deleted, structured reason).
        $rp = Test-WatchdogTelemetryDirectoryReparse -Directory $dir
        if (-not [bool]$rp.ok) {
            if ([string]$rp.reason -ceq 'no-directory') {
                $res['reason'] = 'no-directory'
                return [PSCustomObject]$res
            }
            if ([string]$rp.reason -ceq 'reparse-detected') {
                $res['reason'] = 'reparse-detected'
                return [PSCustomObject]$res
            }
            $res['ok'] = $false
            $res['reason'] = [string]$rp.reason
            return [PSCustomObject]$res
        }
        # FIX5: a zero examined-cap means "examine NOTHING", so return
        # BEFORE any enumerator exists - the directory is not even listed.
        if ($maxExam -le 0) {
            $res['reason'] = 'cap-zero'
            return [PSCustomObject]$res
        }
        $now = Get-WatchdogUtcNow -AtUtc $AtUtc
        $cutoff = $now.Date.AddDays(-[double]$days)
        # F3/FIX5: incremental enumeration of EVERY file system entry (no
        # glob filter), budget spent per ENTRY VISITED BEFORE any
        # validation: a name outside the pattern, a subdirectory or a
        # malformed stamp all cost the budget, so a hostile directory can
        # never make one append materialize, validate and sort an
        # unbounded list, and no entry is scanned for free. Only the
        # limited batch is validated and ordered, so deletion targets the
        # OLDEST files WITHIN THE EXAMINED BATCH (never a claimed global
        # oldest, which would require scanning everything).
        $batch = New-Object System.Collections.ArrayList
        $examined = 0
        $scanFailed = $false
        $enum = $null
        $it = $null
        try { $enum = [IO.Directory]::EnumerateFileSystemEntries([string]$dir); $it = $enum.GetEnumerator() }
        catch { $scanFailed = $true }
        if ([bool]$scanFailed) {
            $res['ok'] = $false
            $res['reason'] = 'scan-failed'
            return [PSCustomObject]$res
        }
        try {
            while ($examined -lt [int]$maxExam) {
                $has = $false
                try { $has = [bool]$it.MoveNext() } catch { $scanFailed = $true; break }
                if (-not $has) { break }
                $examined++
                $p = ''
                try { $p = [string]$it.Current } catch { $p = '' }
                $leaf = ''
                try { $leaf = [IO.Path]::GetFileName([string]$p) } catch { $leaf = '' }
                if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
                $rx = [regex]::Match($leaf, '^watchdog-(\d{8})\.jsonl$')
                if (-not $rx.Success) { continue }
                $stamp = [string]$rx.Groups[1].Value
                $day = $null
                try {
                    $yy = [int]$stamp.Substring(0, 4)
                    $mm = [int]$stamp.Substring(4, 2)
                    $dd = [int]$stamp.Substring(6, 2)
                    $day = [DateTime]::new($yy, $mm, $dd, 0, 0, 0, [DateTimeKind]::Utc)
                }
                catch { $day = $null }
                if ($null -eq $day) { continue }
                # A DIRECTORY that happens to carry a telemetry-looking
                # name is never deleted: it spent budget, it is kept.
                $isDirEntry = $false
                try {
                    $ea = [int][IO.File]::GetAttributes([string]$p)
                    $isDirEntry = (($ea -band [int][IO.FileAttributes]::Directory) -ne 0)
                }
                catch { continue }
                if ($isDirEntry) { $res['retained'] = ([int]$res['retained'] + 1); continue }
                [void]$batch.Add([PSCustomObject]@{ path = [string]$p; name = $leaf; day = $day })
            }
            # FIX5: truncation is reported CONSERVATIVELY from the counter
            # itself. No probe MoveNext here: a peek would visit one more
            # entry OUTSIDE the budget (and would enumerate at all when
            # the cap is 0).
            if ((-not [bool]$scanFailed) -and ($examined -ge [int]$maxExam)) { $res['truncated'] = $true }
        }
        finally { try { if ($null -ne $it) { $it.Dispose() } } catch { } }
        $res['examined'] = [int]$examined
        if ([bool]$scanFailed) {
            $res['ok'] = $false
            $res['reason'] = 'scan-failed'
            return [PSCustomObject]$res
        }
        $ordered = @($batch | Sort-Object -Property name)
        foreach ($c in @($ordered)) {
            if ($c.day -ge $cutoff) { $res['retained'] = ([int]$res['retained'] + 1); continue }
            if ([int]$res['deleted'] -ge [int]$maxDel) { $res['retained'] = ([int]$res['retained'] + 1); continue }
            try {
                [IO.File]::Delete([string]$c.path)
                $res['deleted'] = ([int]$res['deleted'] + 1)
            }
            catch { $res['failed'] = ([int]$res['failed'] + 1) }
        }
        # FIX6: the sweep has no cursor, so a non-deletable prefix can eat
        # the whole budget on EVERY call. That starvation is observable,
        # not silent: truncated AND nothing deleted => no_progress (with
        # a structured reason) so an operator can see the sweep is stuck
        # on entries it will never remove. Cursor-based continuation
        # across calls is an accepted residual (judged out of scope:
        # best-effort cleanup in a shadow path, kernel-controlled
        # directory).
        if ([bool]$res['truncated'] -and ([int]$res['deleted'] -eq 0)) {
            $res['no_progress'] = $true
            $res['reason'] = 'no-progress'
        }
        return [PSCustomObject]$res
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; examined = 0; deleted = 0; retained = 0; failed = 0; truncated = $false; no_progress = $false
            retention_days = [int]$days; max_examined = [int]$maxExam; max_deleted = [int]$maxDel; reason = 'internal'
        }
    }
}

function Test-WatchdogTelemetryTailIntact {
    <#
    .SYNOPSIS
        Cheap deterministic FRAMING check for the daily JSONL, run under
        the write gate immediately BEFORE an append (F1): an absent or
        empty file is intact; otherwise the file must END with a
        complete LF-terminated line whose content parses as JSON. At
        most the last 8192 bytes are read, and the inspected line always
        starts at an LF inside that window, so no partial multi-byte
        character is ever decoded and the whole file is never scanned.
        A writer terminated mid-append leaves a fragment without the
        terminating LF (or a non-parsable last line); the caller then
        REFUSES the append with a structured reason, preserving the
        fragment as evidence instead of concatenating the next event
        onto it - losing one event is acceptable, corrupting the file is
        not. Returns @{ok; reason} where reason is '' |
        'tail-incomplete' | 'tail-unreadable'. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Path, [int]$WindowBytes = 8192)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return [PSCustomObject]@{ ok = $true; reason = '' } }
        $len = [long]0
        try {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [PSCustomObject]@{ ok = $true; reason = '' } }
            $len = ([IO.FileInfo]::new($Path)).Length
        }
        catch { return [PSCustomObject]@{ ok = $false; reason = 'tail-unreadable' } }
        if ([long]$len -eq 0) { return [PSCustomObject]@{ ok = $true; reason = '' } }
        $win = 8192
        if ($WindowBytes -lt 64) { $win = 64 }
        if ([long]$win -gt [long]$len) { $win = [int]$len }
        $fs = $null
        $raw = $null
        $read = 0
        try {
            $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            [void]$fs.Seek(([long]$len - [long]$win), [IO.SeekOrigin]::Begin)
            $raw = New-Object byte[] $win
            $read = $fs.Read($raw, 0, $win)
        }
        catch { return [PSCustomObject]@{ ok = $false; reason = 'tail-unreadable' } }
        finally { try { if ($null -ne $fs) { $fs.Dispose() } } catch { } }
        if ($read -le 0) { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
        if ([int]$read -lt $win) {
            $slice = New-Object byte[] $read
            [Array]::Copy($raw, 0, $slice, 0, [int]$read)
        }
        else { $slice = $raw }
        if ($slice[$slice.Length - 1] -ne 10) { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
        $endIdx = ($slice.Length - 1)
        $startIdx = -1
        for ($i = ($endIdx - 1); $i -ge 0; $i--) {
            if ($slice[$i] -eq 10) { $startIdx = $i; break }
        }
        if ($startIdx -lt 0) { $startIdx = 0 }
        $lineLen = ($endIdx - $startIdx)
        if ($lineLen -le 0) { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
        $lineBytes = New-Object byte[] $lineLen
        [Array]::Copy($slice, $startIdx, $lineBytes, 0, $lineLen)
        $line = ''
        try { $line = [Text.Encoding]::UTF8.GetString($lineBytes) } catch { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
        if ([string]::IsNullOrWhiteSpace($line)) { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
        try { [void]($line | ConvertFrom-Json) } catch { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
        return [PSCustomObject]@{ ok = $true; reason = '' }
    }
    catch { return [PSCustomObject]@{ ok = $false; reason = 'tail-incomplete' } }
}

function Write-WatchdogTelemetryEvent {
    <#
    .SYNOPSIS
        Appends one sanitized shadow event (hashed ids, closed event
        tokens, small ints/bools only; never raw args/values) to the
        daily watchdog JSONL. Phase 26 adds the enforce event family
        (WATCHDOG_INTERRUPTED, WATCHDOG_INTERRUPT_FAILED,
        WATCHDOG_INTERRUPT_REFUSED, WATCHDOG_SETTLED,
        WATCHDOG_NO_PROCESS_IDENTITY); with -Enforce they are filed
        under source 'watchdog-enforce' with shadow=false, through the
        same caps and lock. Check (pre-size accounting) + append run
        atomically under an exclusive in-process lock (Monitor on a
        script-scope object; PS 5.1 compatible, released in finally)
        AND, for cross-process coordination, under a NAMED kernel mutex
        whose name is deterministic from the telemetry directory
        (Enter-WatchdogTelemetryWriteGate): acquired with a bounded wait
        (default 300 ms), so contention SKIPS the write with an honest
        reason ('lock-busy') instead of blocking the caller path, and an
        abandoned mutex (holder died mid-append) also skips
        ('mutex-abandoned') instead of appending after a possibly
        truncated line; an unopenable mutex skips ('mutex-unavailable').
        Because the OS only reports abandonment while the mutex OBJECT
        survives (an observer handle), the abandonment signal alone
        cannot protect the framing: before every append, under the gate,
        Test-WatchdogTelemetryTailIntact verifies the file ends with a
        complete LF-terminated JSON line and otherwise refuses the event
        ('tail-incomplete', fragment preserved as evidence; an unreadable
        file is 'tail-unreadable'). Losing one event is acceptable,
        corrupting the JSONL is not.
        The telemetry directory is resolved EXACTLY ONCE per call and
        that absolute value is PINNED for the whole operation: target
        file, cross-process gate and retention sweep all consume it.
        [Environment]::CurrentDirectory is process-wide and mutable, so
        re-resolving a relative root halfway through the call could make
        the sweep delete old telemetry in a DIFFERENT directory than the
        one just written (FIX8).
        Fail-closed: mkdir failure, accounting failure (size unreadable
        or fault-injection seam $script:WatchdogSimulateAccountingFailure
        set for tests) or overflow all refuse the write with a skipped
        code; the file never exceeds the 1 MB rotation cap. A test-only
        telemetry_delay_ms override key (clamped, absent in production)
        sleeps inside the lock before the append of WATCHDOG_SETTLED
        events ONLY, so integration tests deterministically cross the
        enforce deadline with a slow terminal writer without delaying
        earlier events off the pre-terminal gates. After a SUCCESSFUL
        append the bounded multi-day retention sweep runs best-effort
        (Invoke-WatchdogTelemetryRetention) and never changes this
        result. Returns @{ok, skipped}. Never throws, never blocks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [int]$AttemptN = 0,
        [string]$Class = '',
        [bool]$WouldInterrupt = $false,
        [int]$Steps = 0,
        [int]$ElapsedSeconds = 0,
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        [switch]$Enforce
    )
    try {
        $allowed = @('STALL_SUSPECTED', 'WATCHDOG_WOULD_INTERRUPT', 'BUDGET_NEAR_LIMIT', 'NO_PROGRESS_SUSPECTED', 'REPEATED_ACTION_SUSPECTED', 'WATCHDOG_INTERRUPTED', 'WATCHDOG_INTERRUPT_FAILED', 'WATCHDOG_INTERRUPT_REFUSED', 'WATCHDOG_SETTLED', 'WATCHDOG_NO_PROCESS_IDENTITY')
        if ($allowed -cnotcontains ([string]$EventName).Trim().ToUpperInvariant()) {
            return [PSCustomObject]@{ ok = $false; skipped = 'bad-event' }
        }
        $ev = ([string]$EventName).Trim().ToUpperInvariant()
        $cls = ([string]$Class).Trim().ToUpperInvariant()
        $allowedClass = @('HARD_TIMEOUT', 'NO_PROGRESS', 'REPEATED_ACTION', 'REPEATED_CYCLE', 'STALL_SUSPECTED', 'BUDGET_NEAR_LIMIT', 'NONE')
        if ($allowedClass -cnotcontains $cls) { $cls = 'NONE' }
        $doc = [ordered]@{
            ts             = ([DateTimeOffset]::UtcNow.ToString('o'))
            source         = 'watchdog-shadow'
            shadow         = $true
            event          = $ev
            task_hash16    = (Get-WatchdogTaskHash16 -TaskId ([string]$TaskId))
            attempt_n      = [int]$AttemptN
            class          = $cls
            would_interrupt = [bool]$WouldInterrupt
            steps          = [int]$Steps
            elapsed_s      = [int]$ElapsedSeconds
        }
        if ([bool]$Enforce) {
            $doc['source'] = 'watchdog-enforce'
            $doc['shadow'] = $false
        }
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 4 -Compress) }
        catch { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        # FIX8: ONE resolution per operation. The telemetry directory is
        # canonicalized exactly ONCE here and the resulting absolute
        # value is pinned for the whole call: the daily file target, the
        # cross-process gate and the retention sweep all consume THAT
        # value ([Environment]::CurrentDirectory is process-wide and
        # mutable, so re-resolving a relative root later in the call
        # could send the sweep to a different destination than the one
        # that was just written).
        $teleDir = Get-WatchdogTelemetryDirectory -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($teleDir)) { return [PSCustomObject]@{ ok = $false; skipped = 'no-target' } }
        $target = Get-WatchdogTelemetryFile -Directory $teleDir
        if ([string]::IsNullOrWhiteSpace($target)) { return [PSCustomObject]@{ ok = $false; skipped = 'no-target' } }
        $lockTaken = $false
        $gateMutex = $null
        $gateOwned = $false
        $writeResult = $null
        try {
            [System.Threading.Monitor]::Enter($script:WatchdogTelemetryLock, [ref]$lockTaken)
            # Cross-process coordination: bounded named mutex per telemetry
            # directory. Contention/abandonment SKIP the write (honest
            # reason, best-effort observability), never block or throw.
            $gate = Enter-WatchdogTelemetryWriteGate -TelemetryFile $target
            if (-not [bool]$gate.ok) {
                return [PSCustomObject]@{ ok = $false; skipped = [string]$gate.skipped }
            }
            $gateMutex = $gate.mutex
            $gateOwned = [bool]$gate.owned
            try {
                $parent = Split-Path -Parent $target
                if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'mkdir' } }
            try {
                if ([bool]$script:WatchdogSimulateAccountingFailure) {
                    throw [System.IO.IOException]::new('simulated accounting failure')
                }
                $eventBytes = [Text.Encoding]::UTF8.GetByteCount(($text + "`n"))
                $currentLen = [long]0
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $currentLen = ([IO.FileInfo]::new($target)).Length
                }
                if (($currentLen + [long]$eventBytes) -gt [long]$script:WatchdogTelemetryCapBytes) {
                    return [PSCustomObject]@{ ok = $false; skipped = 'rotation-cap' }
                }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'accounting-unavailable' } }
            # F1 framing guard: under the gate, before appending, the
            # tail must be a complete LF-terminated JSON line. A writer
            # terminated mid-append leaves a fragment; appending onto it
            # would concatenate two events into one corrupt line, so the
            # event is dropped (best-effort) and the fragment is kept as
            # evidence.
            $tail = Test-WatchdogTelemetryTailIntact -Path $target
            if (-not [bool]$tail.ok) {
                $tailCode = ([string]$tail.reason).Trim()
                if ([string]::IsNullOrWhiteSpace($tailCode)) { $tailCode = 'tail-incomplete' }
                return [PSCustomObject]@{ ok = $false; skipped = $tailCode }
            }
            try {
                try {
                    $ovw = $script:WatchdogTreeTestOverride
                    if (($null -ne $ovw) -and ($ovw -is [System.Collections.IDictionary]) -and $ovw.Contains('telemetry_delay_ms') -and ($ev -ceq 'WATCHDOG_SETTLED')) {
                        $wms = 0
                        try { $wms = ([int]$ovw['telemetry_delay_ms']) } catch { $wms = 0 }
                        if ($wms -lt 0) { $wms = 0 }
                        if ($wms -gt 15000) { $wms = 15000 }
                        if ($wms -gt 0) { Start-Sleep -Milliseconds ([int]$wms) }
                    }
                }
                catch { }
                [IO.File]::AppendAllText($target, ($text + "`n"), [Text.UTF8Encoding]::new($false))
                $writeResult = [PSCustomObject]@{ ok = $true; skipped = '' }
            }
            catch { $writeResult = [PSCustomObject]@{ ok = $false; skipped = 'write' } }
        }
        finally {
            Exit-WatchdogTelemetryWriteGate -Mutex $gateMutex -Owned $gateOwned
            if ($lockTaken) {
                try { [System.Threading.Monitor]::Exit($script:WatchdogTelemetryLock) } catch { }
            }
        }
        # Bounded retention sweep after a SUCCESSFUL append, with both
        # locks already released: it only touches OTHER days' files, so
        # it never corrupts the event just written and never keeps a
        # contending writer waiting. Best-effort: it never changes the
        # result returned to the caller.
        if (($null -ne $writeResult) -and [bool]$writeResult.ok) {
            try { [void](Invoke-WatchdogTelemetryRetention -Directory $teleDir) } catch { }
        }
        return $writeResult
    }
    catch { return [PSCustomObject]@{ ok = $false; skipped = 'internal' } }
}

# ---------- execution table (in-memory only; never task records) ----------

$script:WatchdogSettleWaitMs = 3000
$script:WatchdogSettleSliceMs = 100
$script:WatchdogLiveQueryCount = 0
$script:WatchdogTreeMaxDepth = 32
$script:WatchdogTreeMaxNodes = 64
$script:WatchdogTreeIdentityToleranceTicks = 10000000
$script:WatchdogTreeTestOverride = $null
$script:WatchdogDisposedCount = 0

function Test-WatchdogFaultInject {
    <#
    .SYNOPSIS
        Closed-set validator for the test-only fault-injection seam.
        '' (absent, the production default) is valid and means no
        injection. Unknown non-empty tokens are invalid. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        return (@('stop_failure', 'cim_failure', 'query_failure', 'tree_enum_failure') -ccontains $v)
    }
    catch { return $false }
}

function Test-WatchdogProcessInt {
    <#
    .SYNOPSIS
        Strict positive process id: exact [int]/[long] in [1, 4194303].
        Rejects bool/string/double. Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]))) { return $false }
        $n = [long]$Value
        return (($n -ge 1) -and ($n -le 4194303))
    }
    catch { return $false }
}

function Close-WatchdogProcessHandle {
    <#
    .SYNOPSIS
        Single choke point for handle disposal (P26-FIX3 FIX3-3,
        hardened P26-FIX5 FIX5-3): disposes a pinned instance and
        bumps the diagnostic counter $script:WatchdogDisposedCount
        (same pattern as WatchdogLiveQueryCount: tests assert
        disposal ran). With the test-only track_handles override key
        set, each closed instance identity is also recorded for
        per-instance disposal accounting (no totals compensation).
        Explicit handle ownership: every fixed instance not
        transferred to the caller is closed here on every exit path
        (excluded candidates, refusals, aborted preparation, refused
        registration/ownership). Never throws.
    #>
    [CmdletBinding()]
    param($Instance)
    try {
        if ($null -ne $Instance) {
            try {
                $ovt = $script:WatchdogTreeTestOverride
                if (($null -ne $ovt) -and ($ovt -is [System.Collections.IDictionary]) -and $ovt.Contains('track_handles')) {
                    $tkt = $false
                    try { $tkt = ([bool]$ovt['track_handles']) } catch { $tkt = $false }
                    if ($tkt -and ($null -ne $script:WatchdogTrackedDisposed)) {
                        try {
                            $dh = ([System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Instance))
                            [void]$script:WatchdogTrackedDisposed.Add([int]$dh)
                        }
                        catch { }
                    }
                }
            }
            catch { }
            try { $Instance.Dispose() } catch { }
            try { $script:WatchdogDisposedCount = ([int]$script:WatchdogDisposedCount + 1) } catch { }
        }
    }
    catch { }
}

function Test-WatchdogDeadlineExceeded {
    <#
    .SYNOPSIS
        Shared enforce-deadline predicate (P26-FIX3 FIX3-1, pure
        except the clock read, unit-testable): $true when a real
        deadline was passed and UtcNow reached it; $false for $null,
        non-DateTime, or a live deadline. Callers fail closed on
        $true (REFUSED/WATCHDOG_DEADLINE_EXCEEDED, never kill, never
        settle). Never throws.
    #>
    [CmdletBinding()]
    param($DeadlineUtc)
    try {
        if (($null -eq $DeadlineUtc) -or (-not ($DeadlineUtc -is [DateTime]))) { return $false }
        return ([DateTime]::UtcNow -ge $DeadlineUtc)
    }
    catch { return $false }
}

function Get-WatchdogLiveProcess {
    <#
    .SYNOPSIS
        Single choke point for live-process resolution (P26-FIX1, F1/F4;
        hardened P26-FIX2 F-A). Every ownership/registration/stop/wait
        decision resolves through here exactly once per phase and then
        operates on the returned INSTANCE handle (never re-resolves by
        PID at kill time, which defeats PID reuse between check and
        stop). The native handle is PINNED here on first access
        ($null = $p.Handle): PS 5.1 (.NET Framework) and PS 7 (.NET
        Core) both cache the process handle on first .Handle access, so
        every later Kill/WaitForExit/HasExited on this instance targets
        the pinned process even if the PID is recycled; a denied or
        failing handle access means the identity is not inspectable
        (inspection_failed, fail-closed, never 'gone'). Distinguishes
        proven absence (CIM/Get-Process 'NoProcessFoundForGivenId' =>
        gone=$true) from inspection failure (any other error =>
        inspection_failed=$true, fail-closed, never 'gone').
        $script:WatchdogLiveQueryCount counts resolutions (diagnostic
        counter, tests assert single-resolution). query_failure
        (test-only) forces the inspection-failure leg. Two further
        test-only override keys (read from
        $script:WatchdogTreeTestOverride, absent in production):
        kill_after_resolve stops the just-resolved OWN test child and
        waits (bounded) for its exit before returning the pinned
        (now-dead) instance, so tests deterministically exercise
        death between resolution and proof capture; track_handles
        records each returned instance identity for per-instance
        disposal accounting. Never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId, [string]$FaultInject = '')
    try { $script:WatchdogLiveQueryCount = ([int]$script:WatchdogLiveQueryCount + 1) } catch { }
    try {
        $fi = ([string]$FaultInject).Trim()
        if ($fi -ceq 'query_failure') {
            return [PSCustomObject]@{ found = $false; gone = $false; inspection_failed = $true; process = $null }
        }
        if ((-not [string]::IsNullOrWhiteSpace($fi)) -and (-not (Test-WatchdogFaultInject -Value $fi))) {
            return [PSCustomObject]@{ found = $false; gone = $false; inspection_failed = $true; process = $null }
        }
        if (-not (Test-WatchdogProcessInt -Value $ProcessId)) {
            return [PSCustomObject]@{ found = $false; gone = $true; inspection_failed = $false; process = $null }
        }
        $pidInt = [int][long]$ProcessId
        $p = $null
        try { $p = Get-Process -Id $pidInt -ErrorAction Stop }
        catch {
            $fq = ''
            try { $fq = ([string]$_.FullyQualifiedErrorId) } catch { $fq = '' }
            if ($fq -like 'NoProcessFoundForGivenId*') {
                return [PSCustomObject]@{ found = $false; gone = $true; inspection_failed = $false; process = $null }
            }
            return [PSCustomObject]@{ found = $false; gone = $false; inspection_failed = $true; process = $null }
        }
        if ($null -eq $p) {
            return [PSCustomObject]@{ found = $false; gone = $true; inspection_failed = $false; process = $null }
        }
        try { $null = $p.Handle }
        catch {
            Close-WatchdogProcessHandle -Instance $p
            return [PSCustomObject]@{ found = $false; gone = $false; inspection_failed = $true; process = $null }
        }
        try {
            $ovr = $script:WatchdogTreeTestOverride
            if (($null -ne $ovr) -and ($ovr -is [System.Collections.IDictionary])) {
                if ($ovr.Contains('kill_after_resolve')) {
                    $kar = $false
                    try { $kar = ([bool]$ovr['kill_after_resolve']) } catch { $kar = $false }
                    if ($kar) {
                        try { Stop-Process -Id ([int]$pidInt) -Force -ErrorAction SilentlyContinue } catch { }
                        $ksw = [System.Diagnostics.Stopwatch]::StartNew()
                        while ($ksw.Elapsed.TotalSeconds -lt 5) {
                            $exited = $false
                            try {
                                $p.Refresh()
                                $exited = ([bool]$p.HasExited)
                            }
                            catch { $exited = $true }
                            if ($exited) { break }
                            Start-Sleep -Milliseconds 50
                        }
                        $ksw.Stop()
                    }
                }
                if ($ovr.Contains('track_handles')) {
                    $trk = $false
                    try { $trk = ([bool]$ovr['track_handles']) } catch { $trk = $false }
                    if ($trk -and ($null -ne $script:WatchdogTrackedResolved)) {
                        try {
                            $hh = ([System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($p))
                            [void]$script:WatchdogTrackedResolved.Add([int]$hh)
                        }
                        catch { }
                    }
                }
            }
        }
        catch { }
        return [PSCustomObject]@{ found = $true; gone = $false; inspection_failed = $false; process = $p }
    }
    catch { return [PSCustomObject]@{ found = $false; gone = $false; inspection_failed = $true; process = $null } }
}

function Get-WatchdogLiveProcessParentId {
    <#
    .SYNOPSIS
        Best-effort parent PID via Win32_Process. Returns @{found, parent_id}.
        A failed CIM query is reported (found=$false), never guessed: the
        callers treat unverifiable parentage as fail-closed (registration
        downgrades to unbound advisory, interrupt refuses). cim_failure
        (test-only) forces the unverifiable leg. Never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if ($fi -ceq 'cim_failure') {
            return [PSCustomObject]@{ found = $false; parent_id = 0 }
        }
        if ((-not [string]::IsNullOrWhiteSpace($fi)) -and (-not (Test-WatchdogFaultInject -Value $fi))) {
            return [PSCustomObject]@{ found = $false; parent_id = 0 }
        }
        $inst = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + [string]$ProcessId) -ErrorAction Stop
        if ($null -eq $inst) { return [PSCustomObject]@{ found = $false; parent_id = 0 } }
        $ppid = 0
        try { $ppid = [int]$inst.ParentProcessId } catch { $ppid = 0 }
        if ($ppid -lt 1) { return [PSCustomObject]@{ found = $false; parent_id = 0 } }
        return [PSCustomObject]@{ found = $true; parent_id = $ppid }
    }
    catch { return [PSCustomObject]@{ found = $false; parent_id = 0 } }
}

function Get-WatchdogChildProcesses {
    <#
    .SYNOPSIS
        Direct-children snapshot via CIM (P26-FIX1, F3 tree kill): one
        level per call; the interrupt descends recursively with a bounded
        depth cap. tree_enum_failure (test-only) or any CIM/parameter
        error returns @{ok=$false} (callers fail closed, never settled).
        LIMITATION (CIM-only, one level per call; RR-P26-JOB-WIRING):
        processes spawned after the snapshot, or that break the parent
        link, are invisible HERE; the enforcement covers the former with
        the job backstop when the attach succeeded (see
        Get-WatchdogVerifiedProcessTree and Invoke-WatchdogProcessInterrupt).
        Never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if ($fi -ceq 'tree_enum_failure') {
            return [PSCustomObject]@{ ok = $false; children = @() }
        }
        if ((-not [string]::IsNullOrWhiteSpace($fi)) -and (-not (Test-WatchdogFaultInject -Value $fi))) {
            return [PSCustomObject]@{ ok = $false; children = @() }
        }
        if (-not (Test-WatchdogProcessInt -Value $ProcessId)) {
            return [PSCustomObject]@{ ok = $false; children = @() }
        }
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId=' + [string][int][long]$ProcessId) -ErrorAction Stop)
        $kids = New-Object System.Collections.ArrayList
        foreach ($r in @($rows)) {
            $kidPid = 0
            try { $kidPid = [int]$r.ProcessId } catch { $kidPid = 0 }
            if ($kidPid -lt 1) { continue }
            [void]$kids.Add([PSCustomObject]@{ process_id = $kidPid })
        }
        return [PSCustomObject]@{ ok = $true; children = ([object[]]$kids.ToArray()) }
    }
    catch { return [PSCustomObject]@{ ok = $false; children = @() } }
}

function Get-WatchdogCimProcessLine {
    <#
    .SYNOPSIS
        One CIM identity line (P26-FIX2 F-B): ParentProcessId + creation
        ticks for a PID. cim_failure / tree_enum_failure (test-only) or
        any CIM error, or an unreadable/unparseable CreationDate,
        returns @{found=$false} (callers fail closed, never guess).
        CreationDate arrives as DateTime on current CIM stacks (or as a
        DMTF string on older ones): both shapes are parsed, anything
        else is unverifiable. Never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if (($fi -ceq 'cim_failure') -or ($fi -ceq 'tree_enum_failure')) {
            return [PSCustomObject]@{ found = $false; parent_id = 0; creation_ticks = 0 }
        }
        if ((-not [string]::IsNullOrWhiteSpace($fi)) -and (-not (Test-WatchdogFaultInject -Value $fi))) {
            return [PSCustomObject]@{ found = $false; parent_id = 0; creation_ticks = 0 }
        }
        if (-not (Test-WatchdogProcessInt -Value $ProcessId)) {
            return [PSCustomObject]@{ found = $false; parent_id = 0; creation_ticks = 0 }
        }
        $inst = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + [string][int][long]$ProcessId) -ErrorAction Stop
        if ($null -eq $inst) {
            return [PSCustomObject]@{ found = $false; parent_id = 0; creation_ticks = 0 }
        }
        $ppid = 0
        try { $ppid = [int]$inst.ParentProcessId } catch { $ppid = 0 }
        $raw = $null
        try { $raw = $inst.CreationDate } catch { $raw = $null }
        $cd = $null
        try {
            if ($raw -is [DateTime]) { $cd = ([DateTime]$raw).ToUniversalTime() }
            elseif (($null -ne $raw) -and (-not [string]::IsNullOrWhiteSpace([string]$raw))) {
                $cd = ([Management.ManagementDateTimeConverter]::ToDateTime([string]$raw)).ToUniversalTime()
            }
        }
        catch { $cd = $null }
        if ($null -eq $cd) {
            return [PSCustomObject]@{ found = $false; parent_id = 0; creation_ticks = 0 }
        }
        return [PSCustomObject]@{ found = $true; parent_id = $ppid; creation_ticks = ([long]$cd.Ticks) }
    }
    catch { return [PSCustomObject]@{ found = $false; parent_id = 0; creation_ticks = 0 } }
}

function Get-WatchdogTreeParentLink {
    <#
    .SYNOPSIS
        Fresh parent link for one PID through the CIM identity line
        (P26-FIX2 F-B). The test-only override
        ($script:WatchdogTreeTestOverride.parent_links, set ONLY by the
        F-B integration test to simulate a PID-reuse orphan, $null in
        production) wins when present; otherwise pure CIM. An
        unverifiable link returns @{found=$false} (caller fails closed).
        Never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId, [string]$FaultInject = '')
    try {
        try {
            $ov = $script:WatchdogTreeTestOverride
            if (($null -ne $ov) -and ($ov -is [System.Collections.IDictionary]) -and $ov.Contains('parent_links')) {
                $pl = $ov['parent_links']
                if (($null -ne $pl) -and ($pl -is [System.Collections.IDictionary]) -and $pl.Contains([int]$ProcessId)) {
                    $v = 0
                    try { $v = [int]$pl[[int]$ProcessId] } catch { $v = 0 }
                    if ($v -gt 0) { return [PSCustomObject]@{ found = $true; parent_id = $v } }
                    return [PSCustomObject]@{ found = $false; parent_id = 0 }
                }
            }
        }
        catch { }
        $line = Get-WatchdogCimProcessLine -ProcessId ([int]$ProcessId) -FaultInject ([string]$FaultInject)
        if (-not [bool]$line.found) {
            return [PSCustomObject]@{ found = $false; parent_id = 0 }
        }
        return [PSCustomObject]@{ found = $true; parent_id = ([int]$line.parent_id) }
    }
    catch { return [PSCustomObject]@{ found = $false; parent_id = 0 } }
}

function Get-WatchdogTreeChildSnapshot {
    <#
    .SYNOPSIS
        One-level descendant snapshot with CIM creation ticks per child
        (P26-FIX2 F-B/F-C): the frontier carries IDENTITY (pid + ticks),
        never a bare PID. tree_enum_failure (test-only) or any CIM error
        returns @{ok=$false} (callers fail closed). A child whose
        CreationDate is unreadable is listed with creation_ticks=0; the
        verifier treats 0 as descendant-unverifiable (never silently
        skipped, never killed). cim_failure is deliberately NOT honored
        here (it poisons identity/parent lines instead): this preserves
        the proven F2/F3 fail-closed legs (enumeration succeeds, the
        fresh parent link fails => descendant-unverifiable). The
        test-only override ($script:WatchdogTreeTestOverride with
        extra_children, $null in production) appends extra candidate
        PIDs resolved through REAL CIM lines, so creations stay honest
        while the parent pointer is simulated. Never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if ($fi -ceq 'tree_enum_failure') {
            return [PSCustomObject]@{ ok = $false; children = @() }
        }
        if ((-not [string]::IsNullOrWhiteSpace($fi)) -and (-not (Test-WatchdogFaultInject -Value $fi))) {
            return [PSCustomObject]@{ ok = $false; children = @() }
        }
        if (-not (Test-WatchdogProcessInt -Value $ProcessId)) {
            return [PSCustomObject]@{ ok = $false; children = @() }
        }
        try {
            $ovd = $script:WatchdogTreeTestOverride
            if (($null -ne $ovd) -and ($ovd -is [System.Collections.IDictionary]) -and $ovd.Contains('enum_delay_ms')) {
                $dms = 0
                try { $dms = ([int]$ovd['enum_delay_ms']) } catch { $dms = 0 }
                if ($dms -lt 0) { $dms = 0 }
                if ($dms -gt 15000) { $dms = 15000 }
                if ($dms -gt 0) { Start-Sleep -Milliseconds ([int]$dms) }
            }
        }
        catch { }
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId=' + [string][int][long]$ProcessId) -ErrorAction Stop)
        $kids = New-Object System.Collections.ArrayList
        $seen = @{}
        foreach ($r in @($rows)) {
            $kidPid = 0
            try { $kidPid = [int]$r.ProcessId } catch { $kidPid = 0 }
            if ($kidPid -lt 1) { continue }
            if ($seen.ContainsKey($kidPid)) { continue }
            $seen[$kidPid] = $true
            $ticks = 0
            try {
                $craw = $r.CreationDate
                if ($craw -is [DateTime]) { $ticks = ([long](([DateTime]$craw).ToUniversalTime().Ticks)) }
                elseif (($null -ne $craw) -and (-not [string]::IsNullOrWhiteSpace([string]$craw))) {
                    $ticks = ([long](([Management.ManagementDateTimeConverter]::ToDateTime([string]$craw)).ToUniversalTime().Ticks))
                }
            }
            catch { $ticks = 0 }
            [void]$kids.Add([PSCustomObject]@{ process_id = $kidPid; creation_ticks = ([long]$ticks) })
        }
        try {
            $ov = $script:WatchdogTreeTestOverride
            if (($null -ne $ov) -and ($ov -is [System.Collections.IDictionary]) -and $ov.Contains('extra_children')) {
                $ec = $ov['extra_children']
                if (($null -ne $ec) -and ($ec -is [System.Collections.IDictionary]) -and $ec.Contains([int]$ProcessId)) {
                    foreach ($xp in @($ec[[int]$ProcessId])) {
                        $xpid = 0
                        try { $xpid = [int]$xp } catch { $xpid = 0 }
                        if (($xpid -lt 1) -or $seen.ContainsKey($xpid)) { continue }
                        $seen[$xpid] = $true
                        $xticks = 0
                        try {
                            $xline = Get-WatchdogCimProcessLine -ProcessId ([int]$xpid) -FaultInject ([string]$FaultInject)
                            if ([bool]$xline.found) { $xticks = ([long]$xline.creation_ticks) }
                        }
                        catch { $xticks = 0 }
                        [void]$kids.Add([PSCustomObject]@{ process_id = $xpid; creation_ticks = ([long]$xticks) })
                    }
                }
            }
        }
        catch { }
        return [PSCustomObject]@{ ok = $true; children = ([object[]]$kids.ToArray()) }
    }
    catch { return [PSCustomObject]@{ ok = $false; children = @() } }
}

function Test-WatchdogTreeGeneration {
    <#
    .SYNOPSIS
        Pure 3-way lineage rule (P26-FIX2 F-B, unit-testable, no I/O).
        Compares a candidate child CIM creation against the verified
        ancestor creation (same CIM source, exact tick comparison):
        'include' when the child is not older than the ancestor (a true
        descendant can never predate its ancestor); 'excluded' when the
        child is older beyond WatchdogTreeIdentityToleranceTicks (proof
        of NON-descendence: a PID-reuse orphan); 'ambiguous' when the
        child is slightly older inside the tolerance band (cross-source
        rounding residue: measured CIM-vs-.NET skew is a few ticks, the
        band is one second) => the caller fails closed and kills
        nothing. Never throws.
    #>
    [CmdletBinding()]
    param([long]$ChildCreationTicks, [long]$AncestorCreationTicks)
    try {
        $tol = 10000000
        try { $tol = ([long]$script:WatchdogTreeIdentityToleranceTicks) } catch { $tol = 10000000 }
        if ($tol -lt 0) { $tol = 0 }
        if ([long]$ChildCreationTicks -ge [long]$AncestorCreationTicks) { return 'include' }
        if (([long]$AncestorCreationTicks - [long]$ChildCreationTicks) -gt [long]$tol) { return 'excluded' }
        return 'ambiguous'
    }
    catch { return 'ambiguous' }
}

function Test-WatchdogProcessIdentity {
    <#
    .SYNOPSIS
        Validates an OWN-process binding AT REGISTRATION time (Phase 26,
        hardened P26-FIX1 F1/F2): PID must be alive now (proven absence vs
        inspection failure distinguished); -ProcessPath (when given) must
        exist and must match the live executable path when retrievable;
        the parent leg is PROOF, never declaration: the CIM query must
        succeed AND the live parent must be the current supervisor ($PID,
        i.e. genuinely our child); a declared -ParentProcessId must equal
        the live parent. CIM-unavailable/divergent/not-supervised =>
        NO hard error: returns @{ok=$true, unbound=$true} and the caller
        registers WITHOUT a binding (advisory WATCHDOG_NO_PROCESS_IDENTITY
        under ENFORCE keeps the frozen P25 HOLD). Identity is by EXACT
        process creation time (tick equality, no tolerance window):
        -ProcessStartTime (when given) must equal the live start time
        tick-for-tick. On success the result also carries proof_at
        (P26-FIX4 FIX4-1, hardened P26-FIX5 FIX5-1): the UTC instant
        captured DURING validation only after explicit life
        confirmation on the pinned instance ($live.HasExited -eq
        $false immediately before capture, before any Dispose);
        without confirmed life there is no proof and validation fails
        closed (INVALID_PROCESS_IDENTITY), so the caller stamps
        last_alive_proof with the validation instant and never with a
        post-validation now(). -FaultInject
        is a test-only seam (closed set,
        default absent, no production effect when omitted). Never throws,
        never kills anything.
    #>
    [CmdletBinding()]
    param($ProcessId, [string]$ProcessPath = '', $ParentProcessId = $null, $ProcessStartTime = $null, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if (-not (Test-WatchdogFaultInject -Value $fi)) {
            return (New-WatchdogError -Code 'INVALID_FAULT_INJECT')
        }
        if (-not (Test-WatchdogProcessInt -Value $ProcessId)) {
            return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process id must be an exact positive integer' })
        }
        $pidInt = [int][long]$ProcessId
        $q = Get-WatchdogLiveProcess -ProcessId $pidInt -FaultInject $fi
        if ([bool]$q.inspection_failed) {
            return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process identity is not inspectable' })
        }
        if (-not [bool]$q.found) {
            return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process id is not alive' })
        }
        $live = $q.process
        $liveStartInit = $null
        try { $liveStartInit = ([DateTime]$live.StartTime).ToUniversalTime() } catch { $liveStartInit = $null }
        $livePath = ''
        try { $livePath = ([string]$live.Path).Trim() } catch { $livePath = '' }
        $proofAtInit = ''
        try { $proofAtInit = ([DateTime]::UtcNow.ToString('o')) } catch { $proofAtInit = '' }
        $proofAliveInit = $false
        try { $proofAliveInit = (-not [bool]$live.HasExited) } catch { $proofAliveInit = $false }
        Close-WatchdogProcessHandle -Instance $live
        $live = $null
        if ((-not $proofAliveInit) -or ([string]::IsNullOrWhiteSpace($proofAtInit))) {
            return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process identity is not provably alive' })
        }
        $regPath = ([string]$ProcessPath).Trim()
        if (-not [string]::IsNullOrWhiteSpace($regPath)) {
            if (-not (Test-Path -LiteralPath $regPath -PathType Leaf)) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process path does not exist' })
            }
            if ((-not [string]::IsNullOrWhiteSpace($livePath)) -and ($regPath -cne $livePath)) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process path does not match the live process' })
            }
        }
        if ([string]::IsNullOrWhiteSpace($livePath) -and (-not [string]::IsNullOrWhiteSpace($regPath))) {
            $livePath = $regPath
        }
        $me = 0
        try { $me = [int]$PID } catch { $me = 0 }
        $declaredGiven = $false
        try { $declaredGiven = ($PSBoundParameters.ContainsKey('ParentProcessId')) -and ($null -ne $ParentProcessId) } catch { $declaredGiven = $false }
        if ([bool]$declaredGiven) {
            if (-not (Test-WatchdogProcessInt -Value $ParentProcessId)) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'parent process id must be an exact positive integer' })
            }
        }
        $parentLive = Get-WatchdogLiveProcessParentId -ProcessId $pidInt -FaultInject $fi
        if (-not [bool]$parentLive.found) {
            return [PSCustomObject]@{ ok = $true; unbound = $true; observed = $null; advisory = 'WATCHDOG_NO_PROCESS_IDENTITY'; detail = 'parent-unverifiable' }
        }
        $parentObs = [int]$parentLive.parent_id
        if ($parentObs -ne $me) {
            return [PSCustomObject]@{ ok = $true; unbound = $true; observed = $null; advisory = 'WATCHDOG_NO_PROCESS_IDENTITY'; detail = 'parent-not-supervised' }
        }
        if ([bool]$declaredGiven) {
            if ([int][long]$ParentProcessId -ne $parentObs) {
                return [PSCustomObject]@{ ok = $true; unbound = $true; observed = $null; advisory = 'WATCHDOG_NO_PROCESS_IDENTITY'; detail = 'parent-mismatch' }
            }
        }
        $liveStart = $liveStartInit
        if ($null -eq $ProcessStartTime) {
            if ($null -eq $liveStart) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process start time is not retrievable' })
            }
        }
        else {
            $wantStart = $null
            try {
                if ($ProcessStartTime -is [DateTime]) { $wantStart = ([DateTime]$ProcessStartTime).ToUniversalTime() }
                else {
                    $dto = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse(([string]$ProcessStartTime).Trim(), [ref]$dto)) { $wantStart = $dto.UtcDateTime }
                }
            }
            catch { $wantStart = $null }
            if (($null -eq $wantStart) -or ($null -eq $liveStart)) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process start time is not comparable' })
            }
            if ([long]$wantStart.Ticks -ne [long]$liveStart.Ticks) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'process start time does not match the live process' })
            }
        }
        $obs = [ordered]@{
            process_id        = $pidInt
            process_path      = $livePath
            parent_process_id = $parentObs
            process_start_time = ''
        }
        try { $obs['process_start_time'] = $liveStart.ToString('o') } catch { $obs['process_start_time'] = '' }
        return [PSCustomObject]@{ ok = $true; unbound = $false; observed = $obs; proof_at = $proofAtInit }
    }
    catch { return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY') }
}

function Test-WatchdogProcessOwnership {
    <#
    .SYNOPSIS
        Re-verifies ownership IMMEDIATELY BEFORE any Stop (Phase 26,
        hardened P26-FIX1 F1/F2/F4): the PID resolves through the single
        live-process choke point (proven gone vs inspection failure
        distinguished; inspection failure => WATCHDOG_INSPECTION_FAILED,
        fail-closed, never 'gone'); the executable path must still match
        the registered one (when a path was registered); the live parent
        must be PROVEN via CIM and must equal the registered parent or
        the current supervisor (a failed CIM query or any divergence =>
        WATCHDOG_INTERRUPT_REFUSED; declared values are never proof);
        the live start time must equal the registered one TICK-FOR-TICK
        (no tolerance window: defeats PID reuse). The current process
        itself is never owned. On success returns the VERIFIED live
        instance handle (owned=$true + process) plus proof_at
        (P26-FIX4 FIX4-1, hardened P26-FIX6 FIX6-1a: UTC instant
        captured first, then life explicitly confirmed on the same
        pinned instance (HasExited -eq $false); proof returned only
        when confirmed, since alive-later implies alive-at-capture).
        Proof absent (unconfirmed life) => not-owned REFUSED with
        detail proof-unavailable even when identity and parentage
        verify (P26-FIX6 FIX6-1b; the pinned instance is still
        disposed via the transfer guard). The test-only
        suppress_proof override key skips proof capture so tests
        deterministically exercise the missing-proof refusal.
        Accepts an execution-like hashtable (unit-testable).
        -FaultInject is a test-only seam (closed set, default absent).
        Never throws, never kills anything.
    #>
    [CmdletBinding()]
    param($Execution, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if (-not (Test-WatchdogFaultInject -Value $fi)) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_FAILED'; detail = 'invalid-fault-inject'; process = $null }
        }
        $proc = $null
        try {
            if (($null -ne $Execution) -and ($Execution -is [System.Collections.IDictionary]) -and $Execution.Contains('process')) {
                $proc = $Execution['process']
            }
        }
        catch { $proc = $null }
        if (($null -eq $proc) -or (-not ($proc -is [System.Collections.IDictionary]))) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_NO_PROCESS_IDENTITY'; process = $null }
        }
        $pidWant = 0
        try { if ($null -ne $proc['process_id']) { $pidWant = [int]$proc['process_id'] } } catch { $pidWant = 0 }
        if ($pidWant -lt 1) { return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_NO_PROCESS_IDENTITY'; process = $null } }
        try {
            if ($pidWant -eq [int]$PID) { return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'self'; process = $null } }
        }
        catch { }
        $q = Get-WatchdogLiveProcess -ProcessId $pidWant -FaultInject $fi
        if ([bool]$q.inspection_failed) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INSPECTION_FAILED'; process = $null }
        }
        if (-not [bool]$q.found) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_PROCESS_GONE'; process = $null }
        }
        $live = $q.process
        $ownTransfer = $false
        $proofAtOwn = ''
        try {
            $suppressProof = $false
            try {
                $ovsp = $script:WatchdogTreeTestOverride
                if (($null -ne $ovsp) -and ($ovsp -is [System.Collections.IDictionary]) -and $ovsp.Contains('suppress_proof')) {
                    try { $suppressProof = ([bool]$ovsp['suppress_proof']) } catch { $suppressProof = $false }
                }
            }
            catch { $suppressProof = $false }
            $stampOwn = ''
            try { $stampOwn = ([DateTime]::UtcNow.ToString('o')) } catch { $stampOwn = '' }
            $aliveOwn = $false
            try { $aliveOwn = (-not [bool]$live.HasExited) } catch { $aliveOwn = $false }
            if ((-not $suppressProof) -and $aliveOwn -and (-not [string]::IsNullOrWhiteSpace($stampOwn))) { $proofAtOwn = $stampOwn }
        }
        catch { $proofAtOwn = '' }
        try {
        $regPath = ''
        try { $regPath = ([string]$proc['process_path']).Trim() } catch { $regPath = '' }
        if (-not [string]::IsNullOrWhiteSpace($regPath)) {
            $livePath = ''
            try { $livePath = ([string]$live.Path).Trim() } catch { $livePath = '' }
            if ([string]::IsNullOrWhiteSpace($livePath)) {
                return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'path-unverifiable'; process = $null }
            }
            if ($livePath -cne $regPath) {
                return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'path-mismatch'; process = $null }
            }
        }
        $regParent = 0
        try { if ($null -ne $proc['parent_process_id']) { $regParent = [int]$proc['parent_process_id'] } } catch { $regParent = 0 }
        $parentLive = Get-WatchdogLiveProcessParentId -ProcessId $pidWant -FaultInject $fi
        if (-not [bool]$parentLive.found) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'parent-unverifiable'; process = $null }
        }
        $me = 0
        try { $me = [int]$PID } catch { $me = 0 }
        if (([int]$parentLive.parent_id -ne $regParent) -and ([int]$parentLive.parent_id -ne $me)) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'parent-mismatch'; process = $null }
        }
        $regStart = ''
        try { if ($null -ne $proc['process_start_time']) { $regStart = ([string]$proc['process_start_time']).Trim() } } catch { $regStart = '' }
        if ([string]::IsNullOrWhiteSpace($regStart)) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'start-time-unverifiable'; process = $null }
        }
        $liveStart = $null
        try { $liveStart = ([DateTime]$live.StartTime).ToUniversalTime() } catch { $liveStart = $null }
        $wantStart = $null
        try {
            $dto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($regStart, [ref]$dto)) { $wantStart = $dto.UtcDateTime }
        }
        catch { $wantStart = $null }
        if (($null -eq $liveStart) -or ($null -eq $wantStart)) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'start-time-unverifiable'; process = $null }
        }
        if ([long]$liveStart.Ticks -ne [long]$wantStart.Ticks) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'start-time-mismatch'; process = $null }
        }
        if ([string]::IsNullOrWhiteSpace($proofAtOwn)) {
            return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'proof-unavailable'; process = $null }
        }
        $ownTransfer = $true
        return [PSCustomObject]@{ owned = $true; reason = ''; process = $live; proof_at = $proofAtOwn }
        }
        finally { if (-not $ownTransfer) { Close-WatchdogProcessHandle -Instance $live } }
    }
    catch { return [PSCustomObject]@{ owned = $false; reason = 'WATCHDOG_INTERRUPT_REFUSED'; detail = 'internal'; process = $null } }
}

function Wait-WatchdogProcessExit {
    <#
    .SYNOPSIS
        Bounded exit confirmation (settlement, P26-FIX1 F4): prefers the
        held INSTANCE handle ($Instance.WaitForExit bounded + HasExited)
        over re-querying by PID. The PID poll (when -ProcessId is given)
        distinguishes proven gone (=> $true) from inspection failure
        (=> $false, fail-closed, never 'gone'). Never throws, never waits
        unboundedly.
    #>
    [CmdletBinding()]
    param([int]$ProcessId = 0, $ProcessInstance = $null, [int]$TimeoutMs = 3000)
    try {
        $budget = [int]$TimeoutMs
        if ($budget -lt 0) { $budget = 0 }
        if ($budget -gt 30000) { $budget = 30000 }
        if ($null -ne $ProcessInstance) {
            try {
                if ([bool]$ProcessInstance.WaitForExit([int]$budget)) { return $true }
            }
            catch { }
            try { if ([bool]$ProcessInstance.HasExited) { return $true } } catch { }
        }
        if ([int]$ProcessId -lt 1) {
            try { if (($null -ne $ProcessInstance) -and ([bool]$ProcessInstance.HasExited)) { return $true } } catch { }
            return $false
        }
        $slice = [int]$script:WatchdogSettleSliceMs
        if ($slice -lt 50) { $slice = 50 }
        if ($slice -gt 1000) { $slice = 1000 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt [long]$budget) {
            $re = Get-WatchdogLiveProcess -ProcessId ([int]$ProcessId)
            if ([bool]$re.inspection_failed) { return $false }
            if ([bool]$re.gone) { return $true }
            Start-Sleep -Milliseconds $slice
        }
        $fin = Get-WatchdogLiveProcess -ProcessId ([int]$ProcessId)
        if ([bool]$fin.inspection_failed) { return $false }
        return ([bool]$fin.gone)
    }
    catch { return $false }
}

function Wait-WatchdogProcessTreeExit {
    <#
    .SYNOPSIS
        Bounded settlement wait over a KILLED instance set (P26-FIX1 F3):
        every handle gets WaitForExit against a SHARED overall deadline
        (WatchdogSettleWaitMs total, never per-process stacking). Returns
        @{exited, pending_count}. Never throws.
    #>
    [CmdletBinding()]
    param($Instances, [int]$TimeoutMs = 3000)
    try {
        $budget = [int]$TimeoutMs
        if ($budget -lt 0) { $budget = 0 }
        if ($budget -gt 30000) { $budget = 30000 }
        $list = @()
        try { $list = @($Instances | Where-Object { $null -ne $_ }) } catch { $list = @() }
        if ($list.Count -eq 0) { return [PSCustomObject]@{ exited = $true; pending_count = 0 } }
        $deadline = ([DateTime]::UtcNow.AddMilliseconds([double]$budget))
        $pending = 0
        foreach ($inst in $list) {
            $remaining = [int](($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -lt 0) { $remaining = 0 }
            $done = $false
            try { $done = [bool]$inst.WaitForExit($remaining) } catch { $done = $false }
            if (-not $done) {
                try { $done = [bool]$inst.HasExited } catch { $done = $false }
            }
            if (-not $done) { $pending++ }
        }
        return [PSCustomObject]@{ exited = ($pending -eq 0); pending_count = $pending }
    }
    catch { return [PSCustomObject]@{ exited = $false; pending_count = -1 } }
}

function Stop-WatchdogVerifiedProcess {
    <#
    .SYNOPSIS
        Stops ONE already-ownership-verified process through its VERIFIED
        INSTANCE handle (P26-FIX1 F1, hardened P26-FIX2 F-A): the kill
        is issued on the instance captured during ownership
        re-verification, never by re-resolving the PID, so a PID reuse
        between check and stop cannot redirect the kill; the instance
        is held by the caller until exit is confirmed, and the Kill
        failure path consults ONLY the same instance (HasExited), never
        a fresh PID lookup that could observe a recycled PID. Without
        an instance, one resolution happens here and a proven-gone PID
        maps to structured already_exited (never throws); an
        uninspectable PID maps to WATCHDOG_INTERRUPT_FAILED (F4).
        stop_failure (test-only) simulates an OS refusal. Single Stop
        attempt, no retry loop. Maps every outcome to a structured
        result, never throws.
    #>
    [CmdletBinding()]
    param([int]$ProcessId = 0, $ProcessInstance = $null, [string]$FaultInject = '')
    try {
        $fi = ([string]$FaultInject).Trim()
        if (-not (Test-WatchdogFaultInject -Value $fi)) {
            return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{ detail = 'invalid fault-inject token' })
        }
        if ($fi -ceq 'stop_failure') {
            return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{ detail = 'stop refused by the operating system' })
        }
        $inst = $ProcessInstance
        $ownsFallback = $false
        $pidInt = [int]$ProcessId
        if ($null -eq $inst) {
            if ($pidInt -lt 1) {
                return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{ detail = 'no verified process instance' })
            }
            $q = Get-WatchdogLiveProcess -ProcessId $pidInt -FaultInject $fi
            if ([bool]$q.inspection_failed) {
                return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{ detail = 'process identity is not inspectable' })
            }
            if (-not [bool]$q.found) {
                return [PSCustomObject]@{ ok = $true; already_exited = $true }
            }
            $inst = $q.process
            $ownsFallback = $true
        }
        try { if ([bool]$inst.HasExited) { if ($ownsFallback) { Close-WatchdogProcessHandle -Instance $inst }; return [PSCustomObject]@{ ok = $true; already_exited = $true } } }
        catch { }
        try { $inst.Kill() }
        catch {
            $exited = $false
            try { $exited = [bool]$inst.HasExited } catch { $exited = $false }
            if ($exited) {
                if ($ownsFallback) { Close-WatchdogProcessHandle -Instance $inst }
                return [PSCustomObject]@{ ok = $true; already_exited = $true }
            }
            return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{ detail = 'stop refused by the operating system' })
        }
        if ($ownsFallback) { Close-WatchdogProcessHandle -Instance $inst }
        return [PSCustomObject]@{ ok = $true; already_exited = $false }
    }
    catch { return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED') }
}

function Get-WatchdogVerifiedProcessTree {
    <#
    .SYNOPSIS
        Snapshot + verify the descendant tree BEFORE any kill (P26-FIX1
        F3, hardened P26-FIX2 F-B/F-C/F-E + P26-FIX3 FIX3-1/2/3,
        two-phase): descends from the verified root through CIM child
        snapshots. The frontier carries IDENTITY (pid + CIM creation
        ticks), never a bare PID, so an orphan whose parent PID was
        recycled cannot slip in (F-B): a candidate enters the
        verifiable set ONLY when (a) it is live-resolvable on its
        pinned handle, (b) its fresh parent link still points at an
        already-verified (or already-excluded) ancestor, (c) its CIM
        creation correlates with its live instance start time inside
        WatchdogTreeIdentityToleranceTicks (recycled-PID guard;
        measured CIM-vs-.NET skew is a few ticks, the band is one
        second), and (d) the pure generation rule
        (Test-WatchdogTreeGeneration) includes it. A clearly-older
        candidate is proof of NON-descendence: it is EXCLUDED from
        the kill set (counted in excluded_count, exclusion is
        transitive to its subtree, never a failure of the operation).
        A candidate in the ambiguous band fails the whole operation
        closed (descendant-ambiguous, nothing killed). The ancestor
        CIM line is correlated with the fixed root instance the same
        way; when the root CIM line is already gone (root exited
        between ownership and snapshot) the fixed instance identity
        (or the registered creation ticks when no instance is held,
        F-D gone path) seeds the ancestor. Gone-path attribution
        (FIX3-2): with -AttributionProofTicks (> 0, ticks of
        lastAliveProof: the last time the registered generation was
        proven alive) only descendants PROBABLY of the registered
        generation are included — exact (pid+ticks) members of
        -AttributionIdentities (the last successfully verified set),
        or creations not newer than the proof; anything newer is
        EXCLUDED (a substitute-PID child can never pass), and anything
        older than its own parent is EXCLUDED as impossible lineage.
        A dead descendant is skipped as a kill target BUT still
        descended into, so a LIVE orphan below it fails closed
        (descendant-unverifiable) instead of silently escaping
        coverage. Depth (WatchdogTreeMaxDepth, 32) and node count
        (WatchdogTreeMaxNodes, 64) caps with a non-empty frontier,
        and the passed DeadlineUtc, fail closed (tree-limit-exceeded /
        tree-deadline-exceeded, nothing killed, never settled)
        (F-C/F-E/FIX3-1): the deadline is checked at level entry,
        after every enumeration/query call, at every candidate, and
        the caller re-checks it immediately before the first kill, so
        a breach during the last enumeration (even one returning
        empty) can never authorize a kill. Handle ownership (FIX3-3):
        every pinned instance created here is either transferred to
        the caller (included descendants on success) or closed via
        Close-WatchdogProcessHandle (excluded candidates always;
        everything accumulated when the operation fails closed).
        LIMITATION (CIM-only view of THIS walk, RR-P26-JOB-WIRING):
        descendants spawned after this snapshot are invisible to the
        CIM walk. When the caller attached the verified root to a Job
        Object BEFORE calling here, such descendants are covered by the
        job backstop (membership by creation tree); when the attach was
        refused or the deadline had already expired they remain
        uncovered by the walk, exactly as before this wiring. Never
        throws, never kills anything.
    #>
    [CmdletBinding()]
    param([int]$RootProcessId, $RootInstance = $null, [long]$RootCreationTicks = 0, $DeadlineUtc = $null, [long]$AttributionProofTicks = 0, $AttributionIdentities = $null, [string]$FaultInject = '')
    $heldIncluded = New-Object System.Collections.ArrayList
    $heldExcluded = New-Object System.Collections.ArrayList
    $okTransfer = $false
    try {
        $fi = ([string]$FaultInject).Trim()
        if (-not (Test-WatchdogFaultInject -Value $fi)) {
            return [PSCustomObject]@{ ok = $false; reason = 'tree-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
        }
        if (-not (Test-WatchdogProcessInt -Value $RootProcessId)) {
            return [PSCustomObject]@{ ok = $false; reason = 'tree-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
        }
        $tol = 10000000
        try { $tol = ([long]$script:WatchdogTreeIdentityToleranceTicks) } catch { $tol = 10000000 }
        if ($tol -lt 0) { $tol = 0 }
        $maxDepth = 32
        try { $maxDepth = ([int]$script:WatchdogTreeMaxDepth) } catch { $maxDepth = 32 }
        if ($maxDepth -lt 1) { $maxDepth = 32 }
        $maxNodes = 64
        try { $maxNodes = ([int]$script:WatchdogTreeMaxNodes) } catch { $maxNodes = 64 }
        if ($maxNodes -lt 1) { $maxNodes = 64 }
        $attrOn = ([long]$AttributionProofTicks -gt 0)
        $attrSet = @{}
        if ($attrOn) {
            try {
                foreach ($e in @($AttributionIdentities)) {
                    $ap = 0
                    try { $ap = ([int]$e.process_id) } catch { $ap = 0 }
                    $at = 0
                    try { $at = ([long]$e.creation_ticks) } catch { $at = 0 }
                    if (($ap -gt 0) -and ($at -gt 0)) { $attrSet[$ap] = $at }
                }
            }
            catch { }
        }
        $ancestorTicks = 0
        if ($null -ne $RootInstance) {
            $instTicks = 0
            try { $instTicks = ([long](([DateTime]$RootInstance.StartTime).ToUniversalTime().Ticks)) } catch { $instTicks = 0 }
            if ($instTicks -le 0) {
                return [PSCustomObject]@{ ok = $false; reason = 'ancestor-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
            }
            $rline = Get-WatchdogCimProcessLine -ProcessId ([int]$RootProcessId) -FaultInject $fi
            if ([bool]$rline.found) {
                if ([long]$rline.creation_ticks -le 0) {
                    return [PSCustomObject]@{ ok = $false; reason = 'ancestor-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                }
                $gap = ([long]$rline.creation_ticks - $instTicks)
                if ($gap -lt 0) { $gap = -$gap }
                if ($gap -gt [long]$tol) {
                    return [PSCustomObject]@{ ok = $false; reason = 'ancestor-ambiguous'; descendants = @(); excluded_count = 0; identities = @() }
                }
                $ancestorTicks = ([long]$rline.creation_ticks)
            }
            else {
                $ancestorTicks = $instTicks
            }
        }
        else {
            if ([long]$RootCreationTicks -le 0) {
                return [PSCustomObject]@{ ok = $false; reason = 'ancestor-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
            }
            $ancestorTicks = ([long]$RootCreationTicks)
        }
        $verifiedIds = @{}
        $excludedIds = @{}
        $visited = @{}
        $verifiedIds[[int]$RootProcessId] = ([long]$ancestorTicks)
        $visited[[int]$RootProcessId] = $true
        $desc = New-Object System.Collections.ArrayList
        $identRows = New-Object System.Collections.ArrayList
        $frontier = @([int]$RootProcessId)
        $excludedCount = 0
        $depth = 0
        while ($frontier.Count -gt 0) {
            if ($depth -ge [int]$maxDepth) {
                return [PSCustomObject]@{ ok = $false; reason = 'tree-limit-exceeded'; descendants = @(); excluded_count = 0; identities = @() }
            }
            if ($visited.Count -ge [int]$maxNodes) {
                return [PSCustomObject]@{ ok = $false; reason = 'tree-limit-exceeded'; descendants = @(); excluded_count = 0; identities = @() }
            }
            if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) {
                return [PSCustomObject]@{ ok = $false; reason = 'tree-deadline-exceeded'; descendants = @(); excluded_count = 0; identities = @() }
            }
            $depth++
            $next = New-Object System.Collections.ArrayList
            foreach ($f in $frontier) {
                $enum = Get-WatchdogTreeChildSnapshot -ProcessId ([int]$f) -FaultInject $fi
                if (-not [bool]$enum.ok) {
                    return [PSCustomObject]@{ ok = $false; reason = 'tree-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                }
                if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) {
                    return [PSCustomObject]@{ ok = $false; reason = 'tree-deadline-exceeded'; descendants = @(); excluded_count = 0; identities = @() }
                }
                foreach ($kid in @($enum.children)) {
                    if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) {
                        return [PSCustomObject]@{ ok = $false; reason = 'tree-deadline-exceeded'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    $kidPid = 0
                    try { $kidPid = [int]$kid.process_id } catch { $kidPid = 0 }
                    if ($kidPid -lt 1) { continue }
                    if ($visited.ContainsKey($kidPid)) { continue }
                    $visited[$kidPid] = $true
                    $q = Get-WatchdogLiveProcess -ProcessId $kidPid -FaultInject $fi
                    if ([bool]$q.inspection_failed) {
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    if (-not [bool]$q.found) {
                        [void]$next.Add($kidPid)
                        continue
                    }
                    $link = Get-WatchdogTreeParentLink -ProcessId $kidPid -FaultInject $fi
                    if (-not [bool]$link.found) {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    $parentVerified = $verifiedIds.ContainsKey([int]$link.parent_id)
                    $parentExcluded = $excludedIds.ContainsKey([int]$link.parent_id)
                    if ((-not $parentVerified) -and (-not $parentExcluded)) {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    $rowTicks = 0
                    try { $rowTicks = ([long]$kid.creation_ticks) } catch { $rowTicks = 0 }
                    if ($rowTicks -le 0) {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    $liveTicks = 0
                    try { $liveTicks = ([long](([DateTime]$q.process.StartTime).ToUniversalTime().Ticks)) } catch { $liveTicks = 0 }
                    if ($liveTicks -le 0) {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    $skew = ($rowTicks - $liveTicks)
                    if ($skew -lt 0) { $skew = -$skew }
                    if ($skew -gt [long]$tol) {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-unverifiable'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    if ($parentExcluded) {
                        $excludedIds[$kidPid] = $true
                        $excludedCount++
                        [void]$heldExcluded.Add($q.process)
                        [void]$next.Add($kidPid)
                        continue
                    }
                    if ($attrOn) {
                        $inSet = ($attrSet.ContainsKey($kidPid) -and ([long]$attrSet[$kidPid] -eq [long]$rowTicks))
                        $noNewer = ([long]$rowTicks -le [long]$AttributionProofTicks)
                        $noOlder = ([long]$rowTicks -ge [long]$verifiedIds[[int]$link.parent_id])
                        if (([bool]$inSet) -or (([bool]$noNewer) -and ([bool]$noOlder))) {
                            $verifiedIds[$kidPid] = ([long]$rowTicks)
                            [void]$desc.Add([PSCustomObject]@{ process_id = $kidPid; instance = $q.process })
                            [void]$identRows.Add([PSCustomObject]@{ process_id = $kidPid; creation_ticks = ([long]$rowTicks) })
                            [void]$heldIncluded.Add($q.process)
                            [void]$next.Add($kidPid)
                            continue
                        }
                        $excludedIds[$kidPid] = $true
                        $excludedCount++
                        [void]$heldExcluded.Add($q.process)
                        [void]$next.Add($kidPid)
                        continue
                    }
                    $forcedAmb = $false
                    try {
                        $ovf = $script:WatchdogTreeTestOverride
                        if (($null -ne $ovf) -and ($ovf -is [System.Collections.IDictionary]) -and $ovf.Contains('ambiguous_pids')) {
                            foreach ($ab in @($ovf['ambiguous_pids'])) {
                                $abp = 0
                                try { $abp = ([int]$ab) } catch { $abp = 0 }
                                if (($abp -gt 0) -and ($abp -eq $kidPid)) { $forcedAmb = $true; break }
                            }
                        }
                    }
                    catch { $forcedAmb = $false }
                    if ($forcedAmb) {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-ambiguous'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    $gen = Test-WatchdogTreeGeneration -ChildCreationTicks ([long]$rowTicks) -AncestorCreationTicks ([long]$verifiedIds[[int]$link.parent_id])
                    if ($gen -ceq 'ambiguous') {
                        Close-WatchdogProcessHandle -Instance $q.process
                        return [PSCustomObject]@{ ok = $false; reason = 'descendant-ambiguous'; descendants = @(); excluded_count = 0; identities = @() }
                    }
                    if ($gen -ceq 'excluded') {
                        $excludedIds[$kidPid] = $true
                        $excludedCount++
                        [void]$heldExcluded.Add($q.process)
                        [void]$next.Add($kidPid)
                        continue
                    }
                    $verifiedIds[$kidPid] = ([long]$rowTicks)
                    [void]$desc.Add([PSCustomObject]@{ process_id = $kidPid; instance = $q.process })
                    [void]$identRows.Add([PSCustomObject]@{ process_id = $kidPid; creation_ticks = ([long]$rowTicks) })
                    [void]$heldIncluded.Add($q.process)
                    [void]$next.Add($kidPid)
                }
            }
            $frontier = @($next.ToArray())
        }
        $okTransfer = $true
        return [PSCustomObject]@{ ok = $true; reason = ''; descendants = ([object[]]$desc.ToArray()); excluded_count = ([int]$excludedCount); identities = ([object[]]$identRows.ToArray()) }
    }
    catch { return [PSCustomObject]@{ ok = $false; reason = 'tree-unverifiable'; descendants = @(); excluded_count = 0; identities = @() } }
    finally {
        foreach ($xh in @($heldExcluded.ToArray())) { Close-WatchdogProcessHandle -Instance $xh }
        if (-not $okTransfer) {
            foreach ($ih in @($heldIncluded.ToArray())) { Close-WatchdogProcessHandle -Instance $ih }
        }
    }
}

function Get-WatchdogStoredTerminalResult {
    <#
    .SYNOPSIS
        Central terminal-settlement guard (P26-FIX1 F6): the ONLY place
        that recognizes a terminal settlement. Returns the idempotent
        stored result (settled_before=$true, interrupted flag preserved
        exactly) when the execution already carries SETTLED or
        ALREADY_EXITED, else $null. Both the ENFORCE dispatcher and the
        direct interrupt entry pass through here, so a repeated call by
        ANY entry can never degrade SETTLED into ALREADY_EXITED (or lose
        interrupted=$true). Never throws.
    #>
    [CmdletBinding()]
    param($Execution, [string]$TaskId, [int]$AttemptN, [int]$ElapsedSeconds, [int]$Steps)
    try {
        $stored = $null
        try { $stored = $Execution['enforcement'] } catch { return $null }
        if (($null -eq $stored) -or (-not ($stored -is [System.Collections.IDictionary]))) { return $null }
        $storedSettle = ''
        try { if ($null -ne $stored['settlement']) { $storedSettle = ([string]$stored['settlement']).Trim().ToUpperInvariant() } } catch { return $null }
        if (($storedSettle -ceq 'SETTLED') -or ($storedSettle -ceq 'ALREADY_EXITED')) {
            $storedCls = ''
            try { if ($null -ne $stored['classification']) { $storedCls = ([string]$stored['classification']).Trim().ToUpperInvariant() } } catch { $storedCls = '' }
            $storedInt = $false
            try { if ($null -ne $stored['interrupted']) { $storedInt = [bool]$stored['interrupted'] } } catch { $storedInt = $false }
            $storedTele = ''
            try { if ($null -ne $stored['telemetry_file']) { $storedTele = ([string]$stored['telemetry_file']).Trim() } } catch { $storedTele = '' }
            return [PSCustomObject]@{
                ok = $true; task_id = ([string]$TaskId).Trim(); attempt_n = [int]$AttemptN; enforced = $true
                classification = $storedCls; interrupted = $storedInt; settlement = $storedSettle
                elapsed_s = [int]$ElapsedSeconds; steps = [int]$Steps; telemetry_file = $storedTele; settled_before = $true
            }
        }
        return $null
    }
    catch { return $null }
}

function Stop-WatchdogVerifiedDescendants {
    <#
    .SYNOPSIS
        Stops every verified descendant instance (P26-FIX2 F-D, hardened
        P26-FIX4 FIX4-2): one attempt each on the held instances, no
        PID re-resolution, no retry loop. The shared enforce deadline
        is carried into the loop (-DeadlineUtc) and re-checked before
        every stop: on breach the loop breaks immediately with
        expired=$true (the caller turns a partial kill set into
        FAILED/PENDING with preserved evidence, never terminal).
        Already-exited descendants are simply not added to the killed
        set; a failed stop flags failed=$true (the caller fails
        closed). A test-only stop_delay_ms hook (clamped, skipped for
        the first stop of the call, absent in production) lets
        integration tests expire the deadline between kills. Returns
        @{killed, failed, expired}. Never throws, never waits here:
        the caller runs ONE shared bounded wait over the full killed
        set against the shared enforce deadline.
    #>
    [CmdletBinding()]
    param($Descendants, [string]$FaultInject = '', $DeadlineUtc = $null)
    try {
        $fi = ([string]$FaultInject).Trim()
        $killed = New-Object System.Collections.ArrayList
        $failed = $false
        $expired = $false
        $sidx = 0
        foreach ($d in @($Descendants)) {
            $dInst = $null
            try { $dInst = $d.instance } catch { $dInst = $null }
            if ($null -eq $dInst) { $failed = $true; continue }
            if ($sidx -ge 1) {
                try {
                    $ovs = $script:WatchdogTreeTestOverride
                    if (($null -ne $ovs) -and ($ovs -is [System.Collections.IDictionary]) -and $ovs.Contains('stop_delay_ms')) {
                        $sms = 0
                        try { $sms = ([int]$ovs['stop_delay_ms']) } catch { $sms = 0 }
                        if ($sms -lt 0) { $sms = 0 }
                        if ($sms -gt 10000) { $sms = 10000 }
                        if ($sms -gt 0) { Start-Sleep -Milliseconds ([int]$sms) }
                    }
                }
                catch { }
            }
            $sidx++
            if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) { $failed = $true; $expired = $true; break }
            $ds = $null
            try { $ds = Stop-WatchdogVerifiedProcess -ProcessInstance $dInst -FaultInject $fi } catch { $ds = $null }
            if (($null -ne $ds) -and ([bool]$ds.ok) -and (-not [bool]$ds.already_exited)) { [void]$killed.Add($dInst) }
            elseif (($null -eq $ds) -or (-not [bool]$ds.ok)) { $failed = $true }
        }
        return [PSCustomObject]@{ killed = ([object[]]$killed.ToArray()); failed = [bool]$failed; expired = [bool]$expired }
    }
    catch { return [PSCustomObject]@{ killed = @(); failed = $true; expired = $false } }
}

function Invoke-WatchdogPreKillGate {
    <#
    .SYNOPSIS
        Last deadline re-check immediately before the first kill
        (P26-FIX3 FIX3-1 (c)), used in BOTH the normal and the
        gone path: a test-only pre-kill delay hook
        ($script:WatchdogTreeTestOverride.pre_kill_delay_ms, clamped,
        absent in production) runs first so integration tests can
        expire the deadline between a passed preparation and the
        kill, then the shared predicate decides. Returns $true when
        the kill is authorized, $false when the deadline expired
        mid-preparation (caller fails closed with
        WATCHDOG_DEADLINE_EXCEEDED, nothing killed). Never throws.
    #>
    [CmdletBinding()]
    param($DeadlineUtc)
    try {
        try {
            $ovk = $script:WatchdogTreeTestOverride
            if (($null -ne $ovk) -and ($ovk -is [System.Collections.IDictionary]) -and $ovk.Contains('pre_kill_delay_ms')) {
                $kms = 0
                try { $kms = ([int]$ovk['pre_kill_delay_ms']) } catch { $kms = 0 }
                if ($kms -lt 0) { $kms = 0 }
                if ($kms -gt 10000) { $kms = 10000 }
                if ($kms -gt 0) { Start-Sleep -Milliseconds ([int]$kms) }
            }
        }
        catch { }
        if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-WatchdogTerminalAction {
    <#
    .SYNOPSIS
        Terminalization gate (P26-FIX5 FIX5-2): called AFTER any
        blocking operation that precedes a terminal settlement store
        (notably the synchronous telemetry write under lock) and
        IMMEDIATELY before persisting SETTLED/ALREADY_EXITED.
        Returns 'proceed' when the deadline is live, 'partial' when it
        expired after at least one kill (caller stores FAILED/PENDING
        with preserved evidence, never terminal), 'refuse' when it
        expired with nothing killed (caller stores REFUSED as
        WATCHDOG_DEADLINE_EXCEEDED). Fail-closed on error. Never
        throws.
        RR-P26-JOB-WIRING-FIX2: -LethalApplied e um BOOLEANO separado
        ("um ato letal autorizado foi aplicado": TerminateJobObject
        retornou ok). Ele NUNCA vira contagem - nao soma em KilledCount, nao
        aparece em killed_count: quem entra como quantidade continua sendo o
        contador real do kill CIM. Com ele: 'partial' quando o prazo
        expirou E houve kill CIM OU ato letal do job; 'refuse' somente quando
        o contador real e 0 E o booleano e falso; 'proceed' com prazo vivo.
    #>
    [CmdletBinding()]
    param($DeadlineUtc, [int]$KilledCount = 0, [switch]$LethalApplied)
    $k = 0
    try {
        try { $k = ([int]$KilledCount) } catch { $k = 0 }
        if (-not (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc)) { return 'proceed' }
        if ($k -gt 0) { return 'partial' }
        if ([bool]$LethalApplied) { return 'partial' }
        return 'refuse'
    }
    catch {
        if ($k -gt 0) { return 'partial' }
        if ([bool]$LethalApplied) { return 'partial' }
        return 'refuse'
    }
}

function New-WatchdogDeadlineRefusal {
    <#
    .SYNOPSIS
        Post-deadline refusal with nothing killed (P26-FIX5 FIX5-2
        companion to New-WatchdogPartialFailure): stores settlement
        REFUSED and returns WATCHDOG_DEADLINE_EXCEEDED through the
        same enforce writer (telemetry WATCHDOG_INTERRUPT_REFUSED).
        Used when the deadline expired but no kill happened, so no
        partial evidence exists to preserve. Never throws.
    #>
    [CmdletBinding()]
    param($Execution, [string]$TaskId = '', [int]$AttemptN = 0, [string]$Classification = '', [int]$ElapsedSeconds = 0, [int]$Steps = 0, [string]$TelemetryRoot = '', [string]$RepoRoot = '', [int]$ExcludedCount = 0)
    try {
        $tid = ([string]$TaskId).Trim()
        $cls = ([string]$Classification).Trim().ToUpperInvariant()
        $teleFile = Get-WatchdogTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        $wRef = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN ([int]$AttemptN) -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
        $settleRef = [ordered]@{
            engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
            classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wRef.ok; tree_excluded = ([int]$ExcludedCount)
        }
        try { $Execution['enforcement'] = $settleRef } catch { }
        return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
        })
    }
    catch { return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED') }
}

function New-WatchdogPartialFailure {
    <#
    .SYNOPSIS
        Partial-interruption outcome (P26-FIX4 FIX4-2): the deadline
        expired after at least one kill, so the operation is FAILED
        with settlement PENDING (retryable: a later call resumes the
        remainder; F6 stickiness untouched since PENDING is
        non-terminal) and the evidence of what was already killed is
        preserved (partial=$true, killed_count). NEVER a terminal
        SETTLED/ALREADY_EXITED, and never a REFUSED claiming nothing
        was killed. Emits WATCHDOG_INTERRUPT_FAILED through the same
        enforce writer. Never throws.
        RR-P26-JOB-WIRING-FIX2: -LethalApplied e o BOOLEANO do ato letal
        autorizado aplicado (TerminateJobObject ok). Ele muda APENAS o
        campo interrupted (para que o registro nunca afirme 'nada
        interrompido' depois de um ato letal) e NUNCA entra em killed_count,
        que segue sendo o contador real do kill CIM.
    #>
    [CmdletBinding()]
    param($Execution, [string]$TaskId = '', [int]$AttemptN = 0, [string]$Classification = '', [int]$ElapsedSeconds = 0, [int]$Steps = 0, [string]$TelemetryRoot = '', [string]$RepoRoot = '', [int]$KilledCount = 0, [int]$ExcludedCount = 0, [string]$Detail = '', [switch]$LethalApplied)
    try {
        $tid = ([string]$TaskId).Trim()
        $cls = ([string]$Classification).Trim().ToUpperInvariant()
        $teleFile = Get-WatchdogTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        $wPart = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_FAILED' -TaskId $tid -AttemptN ([int]$AttemptN) -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
        $interruptedPart = (([int]$KilledCount -gt 0) -or [bool]$LethalApplied)
        $settlePart = [ordered]@{
            engaged = $true; interrupted = [bool]$interruptedPart; settlement = 'PENDING'
            partial = $true; killed_count = ([int]$KilledCount)
            classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wPart.ok; tree_excluded = ([int]$ExcludedCount)
        }
        try { $Execution['enforcement'] = $settlePart } catch { }
        $det = ([string]$Detail).Trim()
        if ([string]::IsNullOrWhiteSpace($det)) { $det = 'interrupt partial: deadline expired after kill(s); remainder pending' }
        return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{
            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $det
            partial = $true; killed_count = ([int]$KilledCount)
        })
    }
    catch { return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED') }
}

function ConvertTo-WatchdogJobNote {
    <#
    .SYNOPSIS
        Nota estruturada BOUNDED e sanitizada (RR-P26-JOB-WIRING) para o
        campo job_attach: apenas um rotulo fechado ('attached' ou
        'refused:<motivo>') mais um motivo curto do SO, filtrado para
        [A-Za-z0-9_ ;:.()+-=/], espacos colapsados e teto de 160 chars.
        NUNCA carrega payload livre (caminho, comando, dado). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Prefix = '', [string]$Reason = '')
    $p = ([string]$Prefix).Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { $p = 'refused' }
    $r = ''
    try { $r = [regex]::Replace(([string]$Reason), '[^A-Za-z0-9_ ;:\.\(\)\-\+=/]', ' ') } catch { $r = '' }
    try { $r = [regex]::Replace($r, '\s+', ' ').Trim() } catch { }
    if ([string]::IsNullOrWhiteSpace($r)) { return $p }
    $note = ($p + ':' + $r)
    if ($note.Length -gt 160) { $note = $note.Substring(0, 160) }
    return $note
}

function Close-WatchdogJobBackstop {
    <#
    .SYNOPSIS
        Fecha o handle do job do backstop (RR-P26-JOB-WIRING), idempotente e
        SEM efeito letal: o job do enforcement e criado com -NoKillOnClose,
        logo um REFUSED (nada morto) NUNCA mata o processo que ele reporta
        como nao morto. O unico ato letal do caminho e o
        TerminateJobObject de Complete-WatchdogJobBackstop. Roda em TODOS os
        caminhos de saida (finally), entao nao ha handle vazado: o fato
        do fechamento (job_close_applied + job_close_note) entra no
        registro de settlement, para que a ausencia de leak seja verificavel
        por leitura. Never throws.
    #>
    [CmdletBinding()]
    param($State)
    try {
        if (($null -eq $State) -or ($null -eq $State.job)) { return }
        $r = $null
        try { $r = Close-RuntimeJobObject -Job $State.job } catch { $r = $null }
        if ($null -ne $r) {
            try { $State.close_applied = [bool]$r.Ok } catch { }
            # Nota curta e VERDADEIRA: nao reaproveitamos o texto canned da lib
            # (que descreve KILL_ON_JOB_CLOSE e nao se aplica a este job sem
            # a flag). No sucesso o fato e o proprio booleano; no motivo de
            # recusa a nota carrega o motivo sanitizado e bounded.
            try {
                if ([bool]$r.Ok) { $State.close_note = 'close:handle-fechado' }
                else { $State.close_note = ConvertTo-WatchdogJobNote -Prefix 'close:recusado' -Reason ([string]$r.Reason) }
            }
            catch { }
        }
    }
    catch { }
}

function New-WatchdogJobBackstop {
    <#
    .SYNOPSIS
        RR-P26-JOB-WIRING attach-side: cria o job SEM KILL_ON_JOB_CLOSE e
        atribui a RAIZ VERIFICADA (instancia pinada do proprio enforcement,
        com identidade provada) ANTES do snapshot da arvore, de modo que todo
        spawn POS-attach (inclusive durante a janela de kill) entra no job por
        heranca de criacao. O attach re-verifica barato (liveness +
        identidade) e NUNCA abre handle por PID (seam
        Attach-RuntimeJobVerifiedProcess).
        Recusa => resultado estruturado COM NOTA e o caller segue pelo
        caminho CIM-ONLY de hoje, sem mudanca de comportamento:
          - deadline ja expirado => nenhum attach (a semantica de recusa e
            preservada: nada foi morto nem preparado);
          - job indisponivel/criacao/atribuicao recusada => 'refused:<motivo>';
          - $script:WatchdogTreeTestOverride.job_attach_refuse (TEST-ONLY,
            ausente em producao) => 'refused:test-hook', para exercitar o
            fallback sem depender de um refusal do SO.
        Never throws.
    #>
    [CmdletBinding()]
    param($Instance, [long]$ExpectedCreationTicks = 0, $DeadlineUtc = $null)
    $st = @{ attached = $false; job = $null; note = 'skipped'; kill_applied = $false; settled = $false; members_remaining = -1; members_before = -1; members_reduction = -1; skip = ''; close_applied = $false; close_note = '' }
    try {
        if (-not [bool]$script:WatchdogJobLibReady) { $st.note = 'refused:job-lib-unavailable'; return $st }
        if ((Get-Command Attach-RuntimeJobVerifiedProcess -ErrorAction SilentlyContinue) -eq $null) { $st.note = 'refused:job-seam-missing'; return $st }
        if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) { $st.note = 'refused:deadline-expired'; return $st }
        $forced = $false
        try {
            $ovj = $script:WatchdogTreeTestOverride
            if (($null -ne $ovj) -and ($ovj -is [System.Collections.IDictionary]) -and $ovj.Contains('job_attach_refuse')) {
                try { $forced = [bool]$ovj['job_attach_refuse'] } catch { $forced = $false }
            }
        }
        catch { }
        if ($forced) { $st.note = 'refused:test-hook'; return $st }
        $job = $null
        try { $job = New-RuntimeJobObject -NoKillOnClose } catch { $job = $null }
        if (($null -eq $job) -or (-not [bool]$job.Ok)) {
            $st.note = ConvertTo-WatchdogJobNote -Prefix 'refused:create' -Reason ([string]$job.Reason)
            return $st
        }
        $st.job = $job
        $att = $null
        try {
            $att = Attach-RuntimeJobVerifiedProcess -Job $job -Instance $Instance -ExpectedCreationTicks ([long]$ExpectedCreationTicks)
        }
        catch { $att = $null }
        if (($null -eq $att) -or (-not [bool]$att.Ok)) {
            Close-WatchdogJobBackstop -State $st
            $st.job = $null
            $st.note = ConvertTo-WatchdogJobNote -Prefix 'refused:attach' -Reason ([string]$att.Reason)
            return $st
        }
        $st.attached = $true
        $st.note = 'attached'
        return $st
    }
    catch {
        $st.attached = $false
        $st.note = 'refused:internal'
        Close-WatchdogJobBackstop -State $st
        $st.job = $null
        return $st
    }
}

function Complete-WatchdogJobBackstop {
    <#
    .SYNOPSIS
        RR-P26-JOB-WIRING kill-side backstop: TerminateJobObject (UNICO ato
        letal) + settlement BOUNDED pela lista de membros + Close POR ULTIMO.
        Orcena o caminho do enforcement: snapshot -> kill da arvore
        verificada -> Terminate -> settlement bounded -> Close. O Terminate
        alcanca descendentes criados DEPOIS do snapshot (invisiveis ao kill
        CIM); os descendentes PRE-attach seguem cobertos pelo kill CIM de
        identidade verificada.
        O settlement do job e EVIDENCIA, nunca criterio: a classificacao
        terminal continua exatamente a de hoje (mesmo settlement required),
        porque o deadline compartilhado pode ja estar gasto neste ponto e um
        rebaixamento de SETTLED por causa do poll seria um terminal falso.
        O budget do poll e limitado (min(restante do deadline, teto) e nunca
        dorme alem do deadline absoluto) para nao roubar a janela da espera
        de saida existente. Never throws.
        RR-P26-JOB-WIRING-FIX1 (2 achados HIGH do review):
        HIGH-1: o deadline compartilhado e REVALIDADO IMEDIATAMENTE antes do
        ato letal. Stop-RuntimeJobObject dispara TerminateJobObject ANTES de
        olhar o prazo do proprio polling, entao budget=0 nao impedia a morte:
        prazo expirado NAO autoriza kill. Expirado => nenhum Terminate, handle
        fechado INERTEMENTE, job_kill_applied=false e a nota bounded
        job_skip='deadline-expired' (o descendente criado depois do snapshot
        SOBREVIVE nesse caso, igual ao comportamento pre-wiring); o caller
        segue as regras de deadline ja existentes (partial com evidencia ou
        REFUSED), sem estado novo.
        HIGH-2 (FIX2): o que alimenta a decisao terminal e o BOOLEANO
        kill_applied (TerminateJobObject retornou ok), NUNCA uma contagem:
        nao soma em KilledCount e nao aparece em killed_count, que seguem
        sendo so o contador real do kill CIM. A lista de membros e
        fotografada antes do Terminate e a diferenca observada vira
        members_reduction (job_members_reduction no registro) - OBSERVACAO
        SEM CAUSALIDADE: os kills do CIM sao assincronos e a espera vem
        depois do backstop, portanto a reducao inclui processos que o CIM ja
        tinha matado e tambem saidas naturais; nenhum consumidor a trata como
        autoria.
        JANELAS RESIDUAIS ACEITAS (nao-fixaveis sem mudar API nativa, sem
        claim de atomicidade): (a) entre o gate de prazo e a chamada, a API
        TerminateJobObject NAO recebe deadline - um Terminate que comeca
        dentro do prazo pode concluir depois dele; (b) preempcao do processo
        entre a checagem e a chamada (o processo pode sair/mudar nesse
        intervalo, e o SO decide). O gate de prazo reduz a janela, nao a
        elimina.
    #>
    [CmdletBinding()]
    param($State, $DeadlineUtc = $null)
    try {
        if (($null -eq $State) -or (-not [bool]$State.attached) -or ($null -eq $State.job)) { return }
        # RR-P26-JOB-WIRING-FIX1 HIGH-2 (fotografia): membros VIVOS no job
        # imediatamente antes do ato letal. Query bounded e somente-leitura;
        # um handle fechado seria a unica razao de ela falhar.
        $mBefore = $null
        try { $mBefore = Get-RuntimeJobMemberPids -Job $State.job } catch { $mBefore = $null }
        if (($null -ne $mBefore) -and [bool]$mBefore.Ok) {
            try { $State.members_before = [int]$mBefore.Assigned } catch { }
        }
        # RR-P26-JOB-WIRING-FIX1 HIGH-1: revalidacao do deadline compartilhado
        # IMEDIATAMENTE antes do ato letal. Stop-RuntimeJobObject chama
        # TerminateJobObject ANTES de olhar o prazo do proprio polling, logo
        # budget=0 NAO impedia a morte. Expirado => nenhum Terminate, o handle
        # fecha INERTEMENTE, job_kill_applied=false e a nota bounded
        # job_skip='deadline-expired' diz o porque (o descendente criado depois
        # do snapshot SOBREVIVE, igual ao comportamento pre-wiring); o caller
        # segue as regras de deadline existentes (partial com evidencia ou
        # REFUSED), nunca um estado novo.
        if (Test-WatchdogDeadlineExceeded -DeadlineUtc $DeadlineUtc) {
            $State.skip = 'deadline-expired'
            Close-WatchdogJobBackstop -State $State
            return
        }
        $budget = 0
        try { $budget = [int](($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds) } catch { $budget = 0 }
        if ($budget -lt 0) { $budget = 0 }
        if ($budget -gt 1000) { $budget = 1000 }
        $stop = $null
        try { $stop = Stop-RuntimeJobObject -Job $State.job -TimeoutMs ([int]$budget) -PollMs 50 } catch { $stop = $null }
        if ($null -ne $stop) {
            try { $State.kill_applied = [bool]$stop.Terminated } catch { }
            try { $State.settled = [bool]$stop.Settled } catch { }
        }
        $m = $null
        try { $m = Get-RuntimeJobMemberPids -Job $State.job } catch { $m = $null }
        if (($null -ne $m) -and [bool]$m.Ok) {
            try { $State.members_remaining = [int]$m.Assigned } catch { }
        }
        # RR-P26-JOB-WIRING-FIX2 (OBSERVACAO, sem causalidade): quantos
        # membros desapareceram da lista do job entre a foto e o fim do
        # settlement. NAO e contagem de mortos pelo backstop: os kills do CIM
        # sao assincronos (.Kill() sem espera; a espera vem DEPOIS do
        # backstop), logo processos ja mortos pelo CIM ainda aparecem na foto
        # e a saida deles entra nesta reducao; saidas naturais tambem. Por
        # isso o nome e members_reduction e nenhum consumidor trata isso como
        # autoria. O que decide o ramo terminal e o BOOLEANO kill_applied
        # (TerminateJobObject retornou ok), que nunca vira contagem.
        $beforeCount = -1
        try { $beforeCount = [int]$State.members_before } catch { $beforeCount = -1 }
        $afterCount = -1
        try { $afterCount = [int]$State.members_remaining } catch { $afterCount = -1 }
        if (($beforeCount -ge 0) -and ($afterCount -ge 0)) {
            $dropCount = ([int]$beforeCount - [int]$afterCount)
            if ($dropCount -lt 0) { $dropCount = 0 }
            try { $State.members_reduction = [int]$dropCount } catch { }
        }
        Close-WatchdogJobBackstop -State $State
    }
    catch { }
}

function Add-WatchdogJobRecord {
    <#
    .SYNOPSIS
        Acrescenta os campos BOUNDED e sanitizados do backstop de Job Object
        (RR-P26-JOB-WIRING) ao registro de settlement (dicionario vivo: a
        mutacao e vista pelo leitor) e/ou ao resultado (PSCustomObject via
        Add-Member -Force). Campos: job_attach (nota fechada),
        job_attached, job_kill_applied, job_settled, job_members_remaining
        (-1 = consulta inconclusiva/desconhecido), job_close_applied e
        job_close_note (o fechamento do handle do job entra no registro como
        FATO observavel, para que "sem handle vazado" seja verificavel por
        leitura e nao apenas por leitura do codigo), e os campos do FIX1:
        job_skip (bounded; 'deadline-expired' quando o backstop foi pulado
        por prazo, vazio quando rodou), job_members_before e
        job_members_reduction (OBSERVACAO SEM CAUSALIDADE: reducao observada
        da lista de membros do job; kills do CIM ainda pendentes e saidas
        naturais entram nela; -1 = desconhecido). NENHUM campo
        existente e lido, removido ou reescrito aqui, entao leitores antigos
        seguem identicos. Never throws.
    #>
    [CmdletBinding()]
    param($Record, $State)
    try {
        if (($null -eq $Record) -or ($null -eq $State)) { return }
        $pairs = [ordered]@{
            job_attach            = [string]$State.note
            job_attached          = [bool]$State.attached
            job_kill_applied      = [bool]$State.kill_applied
            job_settled           = [bool]$State.settled
            job_members_remaining = [int]$State.members_remaining
            job_skip              = [string]$State.skip
            job_members_before    = [int]$State.members_before
            job_members_reduction = [int]$State.members_reduction
            job_close_applied     = [bool]$State.close_applied
            job_close_note        = [string]$State.close_note
        }
        if ($Record -is [System.Collections.IDictionary]) {
            foreach ($k in @($pairs.Keys)) { $Record[$k] = $pairs[$k] }
            return
        }
        foreach ($k in @($pairs.Keys)) {
            try { $Record | Add-Member -NotePropertyName $k -NotePropertyValue $pairs[$k] -Force } catch { }
        }
    }
    catch { }
}

function Invoke-WatchdogProcessInterrupt {
    <#
    .SYNOPSIS
        Bounded safe interruption (Phase 26, hardened P26-FIX1 +
        P26-FIX2 + P26-FIX4 FIX4-1/FIX4-2): terminal stickiness first
        (F6, via Get-WatchdogStoredTerminalResult); ownership
        re-verification with exact creation-time identity and proven
        parentage (F1/F2), refreshing last_alive_proof with the
        validation instant (FIX4-1, never a later now()); inspection
        failure maps to WATCHDOG_INTERRUPT_FAILED with settlement
        PENDING, never settled (F4); two-phase tree kill of the
        verified root instance plus all verified descendants
        (F3 hardened: generation identity, transitive exclusion counted
        in tree_excluded, depth/node caps and a shared preparation
        deadline fail closed with nothing killed); the deadline is
        carried into every stop and re-checked before ANY terminal
        settlement in BOTH paths including the empty gone branch
        (FIX4-2): expiry with kills outstanding => FAILED/PENDING
        partial with preserved evidence (never terminal, never a
        REFUSED claiming nothing died); expiry with nothing killed =>
        WATCHDOG_DEADLINE_EXCEEDED; kill and exit-wait operate on held
        PINNED instance handles (F-A, no PID re-resolution) which are
        disposed after settlement; when the root already left (gone at
        ownership, or between ownership and stop) the VERIFIED
        descendant set is still processed and ALREADY_EXITED is
        returned only after the whole set exits, else FAILED with
        settlement PENDING (F-D); settlement confirms only when every
        killed instance exits within the shared bounded wait, and the
        deadline is revalidated immediately before persisting ANY
        terminal settlement, after the blocking telemetry write
        (P26-FIX5 FIX5-2): expiry with kills outstanding stores
        FAILED/PENDING partial with preserved evidence and never
        terminalizes; expiry with nothing killed stores REFUSED as
        WATCHDOG_DEADLINE_EXCEEDED.
        wait. Sanitized enforce telemetry (same writer, caps and lock
        as shadow events); partial-evidence preservation (result
        references the evaluation snapshot + the telemetry FILE, never
        its content). Refusals and failures are structured results,
        never exceptions, never retry loops. -FaultInject is a
        test-only seam (closed set, default absent).
        RR-P26-JOB-WIRING (normal path only; the gone path keeps the
        CIM-only shape because there is no live root to attach): after
        the identity/ownership gates pass and BEFORE the tree snapshot,
        with the shared deadline re-checked live, an anonymous job
        WITHOUT KILL_ON_JOB_CLOSE is created and the verified root
        instance is attached through Attach-RuntimeJobVerifiedProcess
        (handle retained by the caller, liveness + identity
        re-verified, never OpenProcess by PID, host-self refused). The
        attach makes every spawn AFTER it job member by creation-tree
        inheritance, which the verified-tree snapshot cannot see. A
        refused attach (job unavailable, attach refused, deadline
        already expired) records a bounded note job_attach=
        'refused:<motivo>' and runs the CIM-ONLY path with ZERO change
        of behavior. When attached: the snapshot and the verified
        descendant kill run as before, THEN TerminateJobObject (the one
        lethal act, reaching post-snapshot descendants), THEN the
        bounded job settlement (member list under the shared deadline,
        never sleeping past it) and CloseHandle LAST. The close is
        deliberately NON-lethal so a REFUSED that killed nothing can
        never kill the process it reports as not killed. The job outcome
        is EVIDENCE, not a criterion: the terminal classification still
        requires the same settlement as before (job_settled /
        job_members_remaining are recorded, never a new terminal, never
        a false terminal; job_close_applied/job_close_note publish the
        handle close). RR-P26-JOB-WIRING-FIX1: (HIGH-1) the shared deadline
        is revalidated IMMEDIATELY before the backstop's lethal act, so an
        expired deadline never reaches TerminateJobObject (the job is closed
        inertly and job_skip='deadline-expired' says why; the late descendant
        survives exactly as before this wiring, and the existing
        partial/REFUSED deadline rules apply unchanged); (HIGH-2, FIX2) the
        terminal decision is fed by the BOOLEAN job_kill_applied
        (TerminateJobObject returned ok), never by a count: KilledCount and
        killed_count remain the real CIM-kill count, so neither
        Get-WatchdogTerminalAction nor the interrupted semantics can say
        "nothing interrupted" after a lethal job act (for example a root
        that exited on its own leaving only a post-snapshot descendant).
        job_members_reduction is the observed drop in the job member list
        (before vs after), published as OBSERVATION WITHOUT CAUSALITY: CIM
        kills are asynchronous and their wait happens after the backstop, so
        already-CIM-killed processes and natural exits also land in that
        number. ACCEPTED RESIDUAL WINDOWS (not fixable without a native API
        change; no atomicity claim): (a) TerminateJobObject takes no
        deadline, so a Terminate started inside the deadline may land after
        it; (b) the target process can be preempted between the check and
        the call.
        Residual: a descendant spawned before the
        attach and a descendant of a root that exited before the stop
        stay covered only by the CIM-verified kill, and a Terminate that
        fails with an already-settled CIM set still reports the same
        settlement as before (evidence only). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        $Execution,
        [Parameter(Mandatory = $true)][string]$Classification,
        [int]$ElapsedSeconds = 0,
        [int]$Steps = 0,
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        [string]$FaultInject = ''
    )
    try {
        $fi = ([string]$FaultInject).Trim()
        if (-not (Test-WatchdogFaultInject -Value $fi)) {
            return (New-WatchdogError -Code 'INVALID_FAULT_INJECT')
        }
        $tid = ([string]$TaskId).Trim()
        $cls = ([string]$Classification).Trim().ToUpperInvariant()
        $attemptN = 0
        try { $attemptN = [int]$Execution['attempt_n'] } catch { $attemptN = 0 }
        $teleFile = Get-WatchdogTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        $terminal = Get-WatchdogStoredTerminalResult -Execution $Execution -TaskId $tid -AttemptN $attemptN -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps)
        if ($null -ne $terminal) { return $terminal }
        $pidWant = 0
        try { $pidWant = [int]$Execution['process']['process_id'] } catch { $pidWant = 0 }
        $own = Test-WatchdogProcessOwnership -Execution $Execution -FaultInject $fi
        if (-not [bool]$own.owned) {
            $reason = ([string]$own.reason).Trim()
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'WATCHDOG_INTERRUPT_REFUSED' }
            if ($reason -ceq 'WATCHDOG_PROCESS_GONE') {
                $regRaw = ''
                try { if ($null -ne $Execution['process']['process_start_time']) { $regRaw = ([string]$Execution['process']['process_start_time']).Trim() } } catch { $regRaw = '' }
                $regTicks = 0
                try {
                    $rdto = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($regRaw, [ref]$rdto)) { $regTicks = ([long]$rdto.UtcDateTime.Ticks) }
                }
                catch { $regTicks = 0 }
                if ($regTicks -le 0) {
                    $wGoneUnv = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                    $settleGoneUnv = [ordered]@{
                        engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'start-time-unverifiable'
                        classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGoneUnv.ok
                    }
                    try { $Execution['enforcement'] = $settleGoneUnv } catch { }
                    return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_REFUSED' -Extra @{
                        task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'start-time-unverifiable'
                    })
                }
                $goneDeadline = ([DateTime]::UtcNow.AddMilliseconds([double][int]$script:WatchdogSettleWaitMs))
                $proofRaw = ''
                try { if ($null -ne $Execution['last_alive_proof']) { $proofRaw = ([string]$Execution['last_alive_proof']).Trim() } } catch { $proofRaw = '' }
                $proofTicks = 0
                try {
                    $pdto = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($proofRaw, [ref]$pdto)) { $proofTicks = ([long]$pdto.UtcDateTime.Ticks) }
                }
                catch { $proofTicks = 0 }
                if ($proofTicks -le 0) {
                    $wGoneAttr = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                    $settleGoneAttr = [ordered]@{
                        engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'attribution-unverifiable'
                        classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGoneAttr.ok
                    }
                    try { $Execution['enforcement'] = $settleGoneAttr } catch { }
                    return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_REFUSED' -Extra @{
                        task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'attribution-unverifiable'
                    })
                }
                $attrIds = @()
                try { $attrIds = @($Execution['last_verified_tree']) } catch { $attrIds = @() }
                $gtree = Get-WatchdogVerifiedProcessTree -RootProcessId ([int]$pidWant) -RootCreationTicks ([long]$regTicks) -DeadlineUtc $goneDeadline -AttributionProofTicks ([long]$proofTicks) -AttributionIdentities $attrIds -FaultInject $fi
                if (-not [bool]$gtree.ok) {
                    $goneTreeDetail = ([string]$gtree.reason).Trim()
                    if ([string]::IsNullOrWhiteSpace($goneTreeDetail)) { $goneTreeDetail = 'tree-unverifiable' }
                    $wGoneTree = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                    $settleGoneTree = [ordered]@{
                        engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = $goneTreeDetail
                        classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGoneTree.ok
                    }
                    try { $Execution['enforcement'] = $settleGoneTree } catch { }
                    if ($goneTreeDetail -ceq 'tree-limit-exceeded') {
                        return (New-WatchdogError -Code 'WATCHDOG_TREE_LIMIT_EXCEEDED' -Extra @{
                            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $goneTreeDetail
                        })
                    }
                    if ($goneTreeDetail -ceq 'tree-deadline-exceeded') {
                        return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $goneTreeDetail
                        })
                    }
                    return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_REFUSED' -Extra @{
                        task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $goneTreeDetail
                    })
                }
                $gexcl = 0
                try { $gexcl = ([int]$gtree.excluded_count) } catch { $gexcl = 0 }
                $gheld = New-Object System.Collections.ArrayList
                foreach ($gd in @($gtree.descendants)) {
                    try { if ($null -ne $gd.instance) { [void]$gheld.Add($gd.instance) } } catch { }
                }
                if (@($gtree.descendants).Count -eq 0) {
                    if (-not (Invoke-WatchdogPreKillGate -DeadlineUtc $goneDeadline)) {
                        $wGoneGateEmpty = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                        $settleGoneGateEmpty = [ordered]@{
                            engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
                            classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGoneGateEmpty.ok; tree_excluded = ([int]$gexcl)
                        }
                        try { $Execution['enforcement'] = $settleGoneGateEmpty } catch { }
                        return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
                        })
                    }
                    $wGone = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_SETTLED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                    $termEmpty = Get-WatchdogTerminalAction -DeadlineUtc $goneDeadline -KilledCount 0
                    if ($termEmpty -ceq 'refuse') {
                        return (New-WatchdogDeadlineRefusal -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -ExcludedCount ([int]$gexcl))
                    }
                    $settleGone = [ordered]@{
                        engaged = $true; interrupted = $false; settlement = 'ALREADY_EXITED'
                        classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGone.ok; tree_excluded = ([int]$gexcl)
                    }
                    if ([int]$gexcl -gt 0) { $settleGone['exclusion'] = 'WATCHDOG_TREE_EXCLUDED' }
                    try { $Execution['enforcement'] = $settleGone } catch { }
                    $resGone = [PSCustomObject]@{
                        ok = $true; task_id = $tid; attempt_n = $attemptN; enforced = $true
                        classification = $cls; interrupted = $false; settlement = 'ALREADY_EXITED'
                        elapsed_s = ([int]$ElapsedSeconds); steps = ([int]$Steps)
                        telemetry_file = $teleFile; reason = 'WATCHDOG_PROCESS_GONE'; tree_excluded = ([int]$gexcl)
                    }
                    if ([int]$gexcl -gt 0) { $resGone | Add-Member -NotePropertyName 'exclusion' -NotePropertyValue 'WATCHDOG_TREE_EXCLUDED' -Force }
                    return $resGone
                }
                try {
                    if (-not (Invoke-WatchdogPreKillGate -DeadlineUtc $goneDeadline)) {
                        $wGoneGate = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                        $settleGoneGate = [ordered]@{
                            engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
                            classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGoneGate.ok; tree_excluded = ([int]$gexcl)
                        }
                        try { $Execution['enforcement'] = $settleGoneGate } catch { }
                        return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
                        })
                    }
                    $gdesc = Stop-WatchdogVerifiedDescendants -Descendants @($gtree.descendants) -FaultInject $fi -DeadlineUtc $goneDeadline
                    $gkilled = @($gdesc.killed)
                    $gremain = ([int](($goneDeadline - [DateTime]::UtcNow).TotalMilliseconds))
                    if ($gremain -lt 0) { $gremain = 0 }
                    if ($gremain -gt 30000) { $gremain = 30000 }
                    $gwait = Wait-WatchdogProcessTreeExit -Instances $gkilled -TimeoutMs ([int]$gremain)
                    $gPastDue = Test-WatchdogDeadlineExceeded -DeadlineUtc $goneDeadline
                    if (([bool]$gPastDue) -and ((@($gkilled).Count) -gt 0)) {
                        return (New-WatchdogPartialFailure -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -KilledCount ([int](@($gkilled).Count)) -ExcludedCount ([int]$gexcl) -Detail 'verified descendant set partially interrupted after the deadline; remainder pending')
                    }
                    if ([bool]$gPastDue) {
                        $wGonePast = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                        $settleGonePast = [ordered]@{
                            engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
                            classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGonePast.ok; tree_excluded = ([int]$gexcl)
                        }
                        try { $Execution['enforcement'] = $settleGonePast } catch { }
                        return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                            task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
                        })
                    }
                    if ((-not [bool]$gdesc.failed) -and ([bool]$gwait.exited)) {
                        $wGoneSet = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_SETTLED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                        $termGone = Get-WatchdogTerminalAction -DeadlineUtc $goneDeadline -KilledCount ([int](@($gkilled).Count))
                        if ($termGone -ceq 'partial') {
                            return (New-WatchdogPartialFailure -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -KilledCount ([int](@($gkilled).Count)) -ExcludedCount ([int]$gexcl) -Detail 'settlement crossed the deadline after kill(s); remainder pending')
                        }
                        if ($termGone -ceq 'refuse') {
                            return (New-WatchdogDeadlineRefusal -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -ExcludedCount ([int]$gexcl))
                        }
                        $gInterrupted = ((@($gkilled).Count) -gt 0)
                        $settleGoneSet = [ordered]@{
                            engaged = $true; interrupted = [bool]$gInterrupted; settlement = 'ALREADY_EXITED'
                            classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGoneSet.ok; tree_excluded = ([int]$gexcl)
                        }
                        if ([int]$gexcl -gt 0) { $settleGoneSet['exclusion'] = 'WATCHDOG_TREE_EXCLUDED' }
                        try { $Execution['enforcement'] = $settleGoneSet } catch { }
                        $resGoneSet = [PSCustomObject]@{
                            ok = $true; task_id = $tid; attempt_n = $attemptN; enforced = $true
                            classification = $cls; interrupted = [bool]$gInterrupted; settlement = 'ALREADY_EXITED'
                            elapsed_s = ([int]$ElapsedSeconds); steps = ([int]$Steps)
                            telemetry_file = $teleFile; reason = 'WATCHDOG_PROCESS_GONE'; tree_excluded = ([int]$gexcl)
                        }
                        if ([int]$gexcl -gt 0) { $resGoneSet | Add-Member -NotePropertyName 'exclusion' -NotePropertyValue 'WATCHDOG_TREE_EXCLUDED' -Force }
                        return $resGoneSet
                    }
                    $wGonePend = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_FAILED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                    $settleGonePend = [ordered]@{
                        engaged = $true; interrupted = $true; settlement = 'PENDING'
                        classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGonePend.ok; tree_excluded = ([int]$gexcl)
                    }
                    try { $Execution['enforcement'] = $settleGonePend } catch { }
                    return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{
                        task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'verified descendant set did not settle after the root exited'
                    })
                }
                finally {
                    foreach ($gh in @($gheld.ToArray())) { Close-WatchdogProcessHandle -Instance $gh }
                }
            }
            if ($reason -ceq 'WATCHDOG_INSPECTION_FAILED') {
                $wPend = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_FAILED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settlePend = [ordered]@{
                    engaged = $true; interrupted = $false; settlement = 'PENDING'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wPend.ok
                }
                try { $Execution['enforcement'] = $settlePend } catch { }
                return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'process identity is not inspectable'
                })
            }
            $detail = ''
            try { $detail = ([string]$own.detail).Trim() } catch { $detail = '' }
            $wRef = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
            $settleRef = [ordered]@{
                engaged = $true; interrupted = $false; settlement = 'REFUSED'
                classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wRef.ok
            }
            if (-not [string]::IsNullOrWhiteSpace($detail)) { $settleRef['refusal_detail'] = $detail }
            try { $Execution['enforcement'] = $settleRef } catch { }
            $refErr = New-WatchdogError -Code 'WATCHDOG_INTERRUPT_REFUSED' -Extra @{
                task_id = $tid; classification = $cls; telemetry_file = $teleFile
            }
            if (-not [string]::IsNullOrWhiteSpace($detail)) { $refErr | Add-Member -NotePropertyName 'detail' -NotePropertyValue $detail -Force }
            return $refErr
        }
        try {
            $paOwn = ''
            try { $paOwn = ([string]$own.proof_at).Trim() } catch { $paOwn = '' }
            if (-not [string]::IsNullOrWhiteSpace($paOwn)) {
                $pdtoOwn = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($paOwn, [ref]$pdtoOwn)) {
                    $Execution['last_alive_proof'] = $paOwn
                }
            }
        }
        catch { }
        $rootInst = $null
        try { $rootInst = $own.process } catch { $rootInst = $null }
        if ($null -eq $rootInst) {
            $wNoInst = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
            $settleNoInst = [ordered]@{
                engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'verified-instance-missing'
                classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wNoInst.ok
            }
            try { $Execution['enforcement'] = $settleNoInst } catch { }
            return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_REFUSED' -Extra @{
                task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'verified-instance-missing'
            })
        }
        $opDeadline = ([DateTime]::UtcNow.AddMilliseconds([double][int]$script:WatchdogSettleWaitMs))
        $held = New-Object System.Collections.ArrayList
        [void]$held.Add($rootInst)
        # RR-P26-JOB-WIRING: attach-side ANTES do snapshot, com deadline vivo
        # re-checado. A identidade (ticks UTC) e lida da MESMA instancia
        # pinada que o ownership provou; recusa => nota + caminho CIM-ONLY
        # EXATAMENTE como hoje (nenhuma mudanca de comportamento).
        $jobTicks = 0
        try { $jobTicks = ([long](([DateTime]$rootInst.StartTime).ToUniversalTime().Ticks)) } catch { $jobTicks = 0 }
        $jobState = New-WatchdogJobBackstop -Instance $rootInst -ExpectedCreationTicks ([long]$jobTicks) -DeadlineUtc $opDeadline
        try {
            $tree = Get-WatchdogVerifiedProcessTree -RootProcessId ([int]$pidWant) -RootInstance $rootInst -DeadlineUtc $opDeadline -FaultInject $fi
            if (-not [bool]$tree.ok) {
                $treeDetail = ([string]$tree.reason).Trim()
                if ([string]::IsNullOrWhiteSpace($treeDetail)) { $treeDetail = 'tree-unverifiable' }
                $wTree = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settleTree = [ordered]@{
                    engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = $treeDetail
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wTree.ok
                }
                try { $Execution['enforcement'] = $settleTree } catch { }
                if ($treeDetail -ceq 'tree-limit-exceeded') {
                    return (New-WatchdogError -Code 'WATCHDOG_TREE_LIMIT_EXCEEDED' -Extra @{
                        task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $treeDetail
                    })
                }
                if ($treeDetail -ceq 'tree-deadline-exceeded') {
                    return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                        task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $treeDetail
                    })
                }
                return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_REFUSED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = $treeDetail
                })
            }
            $texcl = 0
            try { $texcl = ([int]$tree.excluded_count) } catch { $texcl = 0 }
            try { $Execution['last_verified_tree'] = @($tree.identities) } catch { }
            foreach ($hd in @($tree.descendants)) {
                try { if ($null -ne $hd.instance) { [void]$held.Add($hd.instance) } } catch { }
            }
            if (-not (Invoke-WatchdogPreKillGate -DeadlineUtc $opDeadline)) {
                $wGate = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settleGate = [ordered]@{
                    engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wGate.ok
                }
                try { $Execution['enforcement'] = $settleGate } catch { }
                return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
                })
            }
            $rootGoneEarly = $false
            $killed = New-Object System.Collections.ArrayList
            if (Test-WatchdogDeadlineExceeded -DeadlineUtc $opDeadline) {
                $wRootPast = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settleRootPast = [ordered]@{
                    engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wRootPast.ok; tree_excluded = ([int]$texcl)
                }
                try { $Execution['enforcement'] = $settleRootPast } catch { }
                return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
                })
            }
            $stop = Stop-WatchdogVerifiedProcess -ProcessId ([int]$pidWant) -ProcessInstance $rootInst -FaultInject $fi
            if (-not [bool]$stop.ok) {
                $wFail = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_FAILED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settleFail = [ordered]@{
                    engaged = $true; interrupted = $false; settlement = 'FAILED'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wFail.ok; tree_excluded = ([int]$texcl)
                }
                try { $Execution['enforcement'] = $settleFail } catch { }
                $failErr = New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile
                }
                return $failErr
            }
            if ([bool]$stop.already_exited) { $rootGoneEarly = $true }
            else { [void]$killed.Add($rootInst) }
            $descRes = Stop-WatchdogVerifiedDescendants -Descendants @($tree.descendants) -FaultInject $fi -DeadlineUtc $opDeadline
            foreach ($kk in @($descRes.killed)) { [void]$killed.Add($kk) }
            $descendantFailed = ([bool]$descRes.failed)
            # RR-P26-JOB-WIRING: backstop pos-kill. O Terminate e o unico ato
            # letal e alcanca os descendentes criados DEPOIS do snapshot
            # (invisiveis ao kill CIM). O settlement terminal e o de hoje.
            Complete-WatchdogJobBackstop -State $jobState -DeadlineUtc $opDeadline
            # RR-P26-JOB-WIRING-FIX2: o backstop pode ter alcancado membros que o
            # kill CIM nao alcancou (nascidos depois do snapshot). O que
            # alimenta a decisao terminal e o BOOLEANO do ato letal aplicado
            # (TerminateJobObject ok) - NUNCA uma contagem: killedCount segue
            # sendo exatamente o contador real do kill CIM e e ele que vai
            # para KilledCount/killed_count. Logica: partial com prazo
            # expirado quando houve kill CIM OU ato letal do job; REFUSED
            # somente quando o contador real e 0 E o booleano e falso;
            # interrupted true quando houve qualquer um dos dois.
            $jobLethalApplied = $false
            try { $jobLethalApplied = [bool]$jobState.kill_applied } catch { $jobLethalApplied = $false }
            $killedCount = ([int](@($killed).Count))
            $actAny = (($killedCount -gt 0) -or [bool]$jobLethalApplied)
            $wInt = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPTED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
            $remainMs = ([int](($opDeadline - [DateTime]::UtcNow).TotalMilliseconds))
            if ($remainMs -lt 0) { $remainMs = 0 }
            if ($remainMs -gt 30000) { $remainMs = 30000 }
            $wait = Wait-WatchdogProcessTreeExit -Instances ([object[]]$killed.ToArray()) -TimeoutMs ([int]$remainMs)
            $pastDue = Test-WatchdogDeadlineExceeded -DeadlineUtc $opDeadline
            if (([bool]$pastDue) -and ([bool]$actAny)) {
                return (New-WatchdogPartialFailure -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -KilledCount ([int]$killedCount) -LethalApplied:$jobLethalApplied -ExcludedCount ([int]$texcl) -Detail 'interrupt partial: deadline expired after kill(s); remainder pending')
            }
            if ([bool]$pastDue) {
                $wPast = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_REFUSED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settlePast = [ordered]@{
                    engaged = $true; interrupted = $false; settlement = 'REFUSED'; refusal_detail = 'tree-deadline-exceeded'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wPast.ok; tree_excluded = ([int]$texcl)
                }
                try { $Execution['enforcement'] = $settlePast } catch { }
                return (New-WatchdogError -Code 'WATCHDOG_DEADLINE_EXCEEDED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'tree-deadline-exceeded'
                })
            }
            if ([bool]$rootGoneEarly) {
                if ((-not $descendantFailed) -and ([bool]$wait.exited)) {
                    $wAlr = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_SETTLED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                    $termAlr = Get-WatchdogTerminalAction -DeadlineUtc $opDeadline -KilledCount ([int]$killedCount) -LethalApplied:$jobLethalApplied
                    if ($termAlr -ceq 'partial') {
                        return (New-WatchdogPartialFailure -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -KilledCount ([int]$killedCount) -LethalApplied:$jobLethalApplied -ExcludedCount ([int]$texcl) -Detail 'settlement crossed the deadline after kill(s); remainder pending')
                    }
                    if ($termAlr -ceq 'refuse') {
                        return (New-WatchdogDeadlineRefusal -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -ExcludedCount ([int]$texcl))
                    }
                    $earlyInterrupted = [bool]$actAny
                    $settleAlr = [ordered]@{
                        engaged = $true; interrupted = [bool]$earlyInterrupted; settlement = 'ALREADY_EXITED'
                        classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wAlr.ok; tree_excluded = ([int]$texcl)
                    }
                    if ([int]$texcl -gt 0) { $settleAlr['exclusion'] = 'WATCHDOG_TREE_EXCLUDED' }
                    try { $Execution['enforcement'] = $settleAlr } catch { }
                    $resAlr = [PSCustomObject]@{
                        ok = $true; task_id = $tid; attempt_n = $attemptN; enforced = $true
                        classification = $cls; interrupted = [bool]$earlyInterrupted; settlement = 'ALREADY_EXITED'
                        elapsed_s = ([int]$ElapsedSeconds); steps = ([int]$Steps)
                        telemetry_file = $teleFile; reason = 'WATCHDOG_PROCESS_GONE'; tree_excluded = ([int]$texcl)
                    }
                    if ([int]$texcl -gt 0) { $resAlr | Add-Member -NotePropertyName 'exclusion' -NotePropertyValue 'WATCHDOG_TREE_EXCLUDED' -Force }
                    Add-WatchdogJobRecord -Record $resAlr -State $jobState
                    return $resAlr
                }
                $wEarlyPend = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_FAILED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $settleEarlyPend = [ordered]@{
                    engaged = $true; interrupted = $true; settlement = 'PENDING'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wEarlyPend.ok; tree_excluded = ([int]$texcl)
                }
                try { $Execution['enforcement'] = $settleEarlyPend } catch { }
                return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{
                    task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'verified descendant set did not settle after the root exited'
                })
            }
            if (([bool]$wait.exited) -and (-not $descendantFailed)) {
                $wSet = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_SETTLED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                $termSet = Get-WatchdogTerminalAction -DeadlineUtc $opDeadline -KilledCount ([int]$killedCount) -LethalApplied:$jobLethalApplied
                if ($termSet -ceq 'partial') {
                    return (New-WatchdogPartialFailure -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -KilledCount ([int]$killedCount) -LethalApplied:$jobLethalApplied -ExcludedCount ([int]$texcl) -Detail 'settlement crossed the deadline after kill(s); remainder pending')
                }
                if ($termSet -ceq 'refuse') {
                    return (New-WatchdogDeadlineRefusal -Execution $Execution -TaskId $tid -AttemptN ([int]$attemptN) -Classification $cls -ElapsedSeconds ([int]$ElapsedSeconds) -Steps ([int]$Steps) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -ExcludedCount ([int]$texcl))
                }
                $settleOk = [ordered]@{
                    engaged = $true; interrupted = $true; settlement = 'SETTLED'
                    classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wSet.ok; tree_excluded = ([int]$texcl)
                }
                if ([int]$texcl -gt 0) { $settleOk['exclusion'] = 'WATCHDOG_TREE_EXCLUDED' }
                try { $Execution['enforcement'] = $settleOk } catch { }
                $resOk = [PSCustomObject]@{
                    ok = $true; task_id = $tid; attempt_n = $attemptN; enforced = $true
                    classification = $cls; interrupted = $true; settlement = 'SETTLED'
                    elapsed_s = ([int]$ElapsedSeconds); steps = ([int]$Steps)
                    telemetry_file = $teleFile; tree_excluded = ([int]$texcl)
                }
                if ([int]$texcl -gt 0) { $resOk | Add-Member -NotePropertyName 'exclusion' -NotePropertyValue 'WATCHDOG_TREE_EXCLUDED' -Force }
                Add-WatchdogJobRecord -Record $resOk -State $jobState
                return $resOk
            }
            $wStill = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_INTERRUPT_FAILED' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps ([int]$Steps) -ElapsedSeconds ([int]$ElapsedSeconds) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
            $settleStill = [ordered]@{
                engaged = $true; interrupted = $true; settlement = 'STILL_RUNNING'
                classification = $cls; telemetry_file = $teleFile; telemetry_written = [bool]$wStill.ok; tree_excluded = ([int]$texcl)
            }
            try { $Execution['enforcement'] = $settleStill } catch { }
            $stillErr = New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED' -Extra @{
                task_id = $tid; classification = $cls; telemetry_file = $teleFile; detail = 'process tree still running after bounded settlement wait'
            }
            return $stillErr
        }
        finally {
            # RR-P26-JOB-WIRING: fecha o handle do job (inerte, idempotente) em
            # TODOS os caminhos de saida e carimba o registro de settlement ja
            # persistido com a evidencia do backstop (o registro e um dicionario
            # vivo, entao a mutacao e vista pelo leitor). Depois, os handles de
            # processo.
            Close-WatchdogJobBackstop -State $jobState
            $storedJob = $null
            try { $storedJob = $Execution['enforcement'] } catch { $storedJob = $null }
            Add-WatchdogJobRecord -Record $storedJob -State $jobState
            foreach ($hh in @($held.ToArray())) { Close-WatchdogProcessHandle -Instance $hh }
        }
    }
    catch { return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED') }
}

function Invoke-WatchdogEnforcement {
    <#
    .SYNOPSIS
        ENFORCE-gate dispatcher shared by Add and Evaluation (Phase 26).
        Returns $null when the evaluation is not interrupting (caller
        keeps the advisory result). With an interrupting class and a
        bound process it runs the safe interrupt; without a bound
        process it stays advisory-only (WATCHDOG_NO_PROCESS_IDENTITY
        telemetry + reason, nothing killed). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        $Execution,
        $Eval,
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = ''
    )
    try {
        if ($null -eq $Eval) { return $null }
        $would = $false
        try { $would = [bool]$Eval.would_interrupt } catch { $would = $false }
        if (-not $would) { return $null }
        $tid = ([string]$TaskId).Trim()
        $cls = ''
        try { $cls = ([string]$Eval.classification).Trim().ToUpperInvariant() } catch { $cls = '' }
        $attemptN = 0
        try { $attemptN = [int]$Execution['attempt_n'] } catch { $attemptN = 0 }
        $elapsed = 0
        try { $elapsed = [int]$Eval.elapsed_s } catch { $elapsed = 0 }
        $steps = 0
        try { $steps = [int]$Eval.steps } catch { $steps = 0 }
        $stored = Get-WatchdogStoredTerminalResult -Execution $Execution -TaskId $tid -AttemptN $attemptN -ElapsedSeconds $elapsed -Steps $steps
        if ($null -ne $stored) { return $stored }
        $hasProc = $false
        try {
            $pn = $Execution['process']
            $hasProc = (($null -ne $pn) -and ($pn -is [System.Collections.IDictionary]) -and ($null -ne $pn['process_id']) -and ([int]$pn['process_id'] -gt 0))
        }
        catch { $hasProc = $false }
        if (-not $hasProc) {
            $teleFile = Get-WatchdogTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
            $wNo = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_NO_PROCESS_IDENTITY' -TaskId $tid -AttemptN $attemptN -Class $cls -WouldInterrupt $true -Steps $steps -ElapsedSeconds $elapsed -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
            return [PSCustomObject]@{
                ok = $true; task_id = $tid; attempt_n = $attemptN; enforced = $true
                classification = $cls; interrupted = $false; advisory = $true
                reason = 'WATCHDOG_NO_PROCESS_IDENTITY'
                elapsed_s = $elapsed; steps = $steps; telemetry_file = $teleFile
                telemetry_written = [bool]$wNo.ok
            }
        }
        return (Invoke-WatchdogProcessInterrupt -TaskId $tid -Execution $Execution -Classification $cls -ElapsedSeconds $elapsed -Steps $steps -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
    }
    catch { return (New-WatchdogError -Code 'WATCHDOG_INTERRUPT_FAILED') }
}

function Get-OrchestrationWatchdogSettlement {
    <#
    .SYNOPSIS
        Queryable post-interrupt settlement state (Phase 26): engaged /
        interrupted / settlement / classification plus the telemetry FILE
        reference (never content), so the kernel/Planner can confirm
        settlement before releasing ownership/lease. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $gate = Get-WatchdogGate -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
        $tid = ([string]$TaskId).Trim()
        if (-not $script:WatchdogExecutions.ContainsKey($tid)) {
            return (New-WatchdogError -Code 'NOT_REGISTERED')
        }
        $exec = $script:WatchdogExecutions[$tid]
        $attemptN = 0
        try { $attemptN = [int]$exec['attempt_n'] } catch { $attemptN = 0 }
        $teleFile = Get-WatchdogTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        $enf = $null
        try { $enf = $exec['enforcement'] } catch { $enf = $null }
        if (($null -eq $enf) -or (-not ($enf -is [System.Collections.IDictionary]))) {
            return [PSCustomObject]@{
                ok = $true; task_id = $tid; attempt_n = $attemptN
                engaged = $false; interrupted = $false; settlement = 'NONE'
                classification = ''; telemetry_file = $teleFile
            }
        }
        $settlement = 'UNKNOWN'
        try { if ($null -ne $enf['settlement']) { $settlement = ([string]$enf['settlement']).Trim().ToUpperInvariant() } } catch { $settlement = 'UNKNOWN' }
        $ecls = ''
        try { if ($null -ne $enf['classification']) { $ecls = ([string]$enf['classification']).Trim().ToUpperInvariant() } } catch { $ecls = '' }
        $eint = $false
        try { if ($null -ne $enf['interrupted']) { $eint = [bool]$enf['interrupted'] } } catch { $eint = $false }
        return [PSCustomObject]@{
            ok = $true; task_id = $tid; attempt_n = $attemptN
            engaged = $true; interrupted = $eint; settlement = $settlement
            classification = $ecls; telemetry_file = $teleFile
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}

function Clear-OrchestrationWatchdogState {
    <#
    .SYNOPSIS
        Test helper: resets the in-memory execution table. Never throws.
    #>
    [CmdletBinding()]
    param()
    try { $script:WatchdogExecutions = @{} } catch { }
}

function Get-WatchdogBudgetSnapshot {
    [CmdletBinding()]
    param($Budget, [string]$BudgetProfile, [string]$Role, [string]$PolicyPath, [string]$RepoRoot)
    try {
        if ($null -ne $Budget) {
            if ((Get-Command Test-ExecutionBudgetObject -ErrorAction SilentlyContinue) -eq $null) {
                return (New-WatchdogError -Code 'BUDGET_LIB_UNAVAILABLE')
            }
            $chk = Test-ExecutionBudgetObject -Budget $Budget
            if (-not [bool]$chk.valid) {
                return (New-WatchdogError -Code 'INVALID_BUDGET' -Extra @{ reasons = ((@($chk.errors) -join ';')) })
            }
            $copy = [ordered]@{}
            foreach ($f in @('profile', 'step_budget', 'wall_clock_seconds', 'no_progress_seconds', 'repeated_action_soft_limit', 'repeated_action_hard_limit', 'cycle_repeat_limit', 'provider_retry_limit')) {
                $v = $null
                if ($Budget -is [System.Collections.IDictionary]) {
                    if ($Budget.Contains($f)) { $v = $Budget[$f] }
                }
                else {
                    $pp = $Budget.PSObject.Properties | Where-Object { $_.Name -ceq $f } | Select-Object -First 1
                    if ($null -ne $pp) { $v = $pp.Value }
                }
                if ($f -ceq 'profile') { $copy[$f] = ([string]$v) }
                else { $copy[$f] = [int]$v }
            }
            return [PSCustomObject]@{ ok = $true; budget = $copy; source = 'explicit' }
        }
        if ((Get-Command Get-ExecutionBudgetProfileBudget -ErrorAction SilentlyContinue) -eq $null) {
            return (New-WatchdogError -Code 'BUDGET_LIB_UNAVAILABLE')
        }
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-WatchdogDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not [string]::IsNullOrWhiteSpace([string]$BudgetProfile)) {
            $b = Get-ExecutionBudgetProfileBudget -Profile ([string]$BudgetProfile) -PolicyPath $pp -RepoRoot $RepoRoot
            if (-not [bool]$b.ok) {
                $code = ([string]$b.error)
                if ([string]::IsNullOrWhiteSpace($code)) { $code = 'INVALID_BUDGET' }
                return (New-WatchdogError -Code $code)
            }
            return [PSCustomObject]@{ ok = $true; budget = $b.budget; source = 'profile' }
        }
        $roleName = ([string]$Role).Trim()
        if ([string]::IsNullOrWhiteSpace($roleName)) { $roleName = 'coder' }
        $rb = Get-ExecutionBudgetForRole -Role $roleName -PolicyPath $pp -RepoRoot $RepoRoot
        if (-not [bool]$rb.ok) {
            $code2 = ([string]$rb.error)
            if ([string]::IsNullOrWhiteSpace($code2)) { $code2 = 'BUDGET_POLICY_INVALID' }
            return (New-WatchdogError -Code $code2)
        }
        return [PSCustomObject]@{ ok = $true; budget = $rb.budget; source = 'role' }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}

function Register-OrchestrationWatchdogExecution {
    <#
    .SYNOPSIS
        Registers an active execution for supervision. Resolves and
        snapshots the canonical budget (explicit object or role/profile via
        the budget lib). Read-only over task records: state lives only in
        this module's in-memory table. Identity rule (documented): the
        key is task_id bound to (attempt_n, session_id). Re-registering
        the SAME identity is idempotent (clock, history and process
        binding preserved); a DIFFERENT identity on the same task_id
        returns IDENTITY_CONFLICT without mutating state. Phase 26: an
        optional OWN-process binding (-ProcessId plus optional
        -ProcessPath, -ParentProcessId, -ProcessStartTime, plus
        test-only -FaultInject) is validated NOW with exact
        creation-time identity and CIM-proven supervisor parentage;
        the registration also snapshots last_alive_proof and an empty
        last_verified_tree set: the proof is the validation instant
        returned by the identity check (P26-FIX4 FIX4-1, captured with
        the live pinned instance, never a later now()) and refreshes
        on every successful ownership re-verification (same source);
        the set refreshes on every successful tree, so a later
        gone-path interrupt can only liquidate descendants
        attributable to the registered generation;
        invalid bindings return INVALID_PROCESS_IDENTITY with no
        mutation, while CIM-unprovable bindings register WITHOUT a
        process (advisory; under ENFORCE the P25 HOLD applies).
        Under gate ENFORCE a registration WITHOUT a process
        binding keeps the honest P25 HOLD
        (WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED, nothing stored): only a
        bound execution can follow the safe interrupt path. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        $AttemptN = 1,
        [string]$SessionId = '',
        [string]$ParentSessionId = '',
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$RuntimeId = '',
        [string]$RuntimeProfile = '',
        $Budget = $null,
        [string]$BudgetProfile = '',
        $StartedAtUtc = $null,
        [string]$PolicyPath = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        $ProcessId = $null,
        [string]$ProcessPath = '',
        $ParentProcessId = $null,
        $ProcessStartTime = $null,
        [string]$FaultInject = ''
    )
    try {
        $gate = Get-WatchdogGate -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
        $wantProcBinding = $false
        try {
            if (($PSBoundParameters.ContainsKey('ProcessId')) -and ($null -ne $ProcessId)) { $wantProcBinding = $true }
            elseif (-not [string]::IsNullOrWhiteSpace($ProcessPath)) { $wantProcBinding = $true }
            elseif (($PSBoundParameters.ContainsKey('ParentProcessId')) -and ($null -ne $ParentProcessId)) { $wantProcBinding = $true }
            elseif ($null -ne $ProcessStartTime) { $wantProcBinding = $true }
        }
        catch { $wantProcBinding = $false }
        if (($gate -ceq 'ENFORCE') -and (-not $wantProcBinding)) {
            return (New-WatchdogError -Code 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED')
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-WatchdogId -Value $tid)) { return (New-WatchdogError -Code 'INVALID_TASK_ID') }
        if (-not (Test-WatchdogAttemptN -Value $AttemptN)) { return (New-WatchdogError -Code 'INVALID_ATTEMPT') }
        $sid = ([string]$SessionId).Trim()
        if (-not (Test-WatchdogId -Value $sid)) { return (New-WatchdogError -Code 'INVALID_SESSION_ID') }
        $psid = ([string]$ParentSessionId).Trim()
        if ((-not [string]::IsNullOrWhiteSpace($psid)) -and (-not (Test-WatchdogId -Value $psid))) {
            return (New-WatchdogError -Code 'INVALID_PARENT_SESSION_ID')
        }
        $role = ([string]$Role).Trim().ToLowerInvariant()
        if (-not (Test-WatchdogId -Value $role)) { return (New-WatchdogError -Code 'INVALID_ROLE') }
        $rid = ([string]$RuntimeId).Trim().ToLowerInvariant()
        if ((-not [string]::IsNullOrWhiteSpace($rid)) -and (-not (Test-WatchdogId -Value $rid))) {
            return (New-WatchdogError -Code 'INVALID_RUNTIME')
        }
        $rprof = ([string]$RuntimeProfile).Trim().ToLowerInvariant()
        if ((-not [string]::IsNullOrWhiteSpace($rprof)) -and (-not (Test-WatchdogId -Value $rprof))) {
            return (New-WatchdogError -Code 'INVALID_RUNTIME_PROFILE')
        }
        $snap = Get-WatchdogBudgetSnapshot -Budget $Budget -BudgetProfile ([string]$BudgetProfile) -Role $role -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$snap.ok) { return $snap }
        $procObs = $null
        if ([bool]$wantProcBinding) {
            $procCheck = Test-WatchdogProcessIdentity -ProcessId $ProcessId -ProcessPath $ProcessPath -ParentProcessId $ParentProcessId -ProcessStartTime $ProcessStartTime -FaultInject ([string]$FaultInject)
            if (-not [bool]$procCheck.ok) { return $procCheck }
            if ([bool]$procCheck.unbound) {
                if ($gate -ceq 'ENFORCE') {
                    return (New-WatchdogError -Code 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED')
                }
                $procObs = $null
            }
            else {
                $procObs = $procCheck.observed
            }
        }
        $b = $snap.budget
        $bg = {
            param($Node, $Name)
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains($Name)) { return $Node[$Name] }
                return $null
            }
            $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
            if ($null -ne $p) { return $p.Value }
            return $null
        }
        $wall = [int](& $bg $b 'wall_clock_seconds')
        $now = Get-WatchdogUtcNow -AtUtc $StartedAtUtc
        $isEnforceGate = ($gate -ceq 'ENFORCE')
        if ($script:WatchdogExecutions.ContainsKey($tid)) {
            $prev = $script:WatchdogExecutions[$tid]
            if (([int]$prev['attempt_n'] -eq [int][long]$AttemptN) -and ([string]$prev['session_id'] -ceq $sid)) {
                return [PSCustomObject]@{
                    ok = $true; task_id = $tid; attempt_n = [int]$prev['attempt_n']
                    budget_source = ([string]$prev['budget_source']); shadow = (-not $isEnforceGate); enforced = $isEnforceGate; idempotent = $true
                }
            }
            return (New-WatchdogError -Code 'IDENTITY_CONFLICT')
        }
        try {
            $ovp = $script:WatchdogTreeTestOverride
            if (($null -ne $ovp) -and ($ovp -is [System.Collections.IDictionary]) -and $ovp.Contains('proof_delay_ms')) {
                $pms = 0
                try { $pms = ([int]$ovp['proof_delay_ms']) } catch { $pms = 0 }
                if ($pms -lt 0) { $pms = 0 }
                if ($pms -gt 15000) { $pms = 15000 }
                if ($pms -gt 0) { Start-Sleep -Milliseconds ([int]$pms) }
            }
        }
        catch { }
        $proofIso = ''
        if (($null -ne $procObs) -and ($null -ne $procCheck) -and ([bool]$procCheck.ok) -and (-not [bool]$procCheck.unbound)) {
            $paValid = $false
            try {
                $paReg = ([string]$procCheck.proof_at).Trim()
                if (-not [string]::IsNullOrWhiteSpace($paReg)) {
                    $paDto = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($paReg, [ref]$paDto)) { $proofIso = $paReg; $paValid = $true }
                }
            }
            catch { $paValid = $false }
            if (-not $paValid) {
                return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY' -Extra @{ detail = 'proof-unavailable' })
            }
        }
        $exec = @{
            task_id            = $tid
            attempt_n          = [int][long]$AttemptN
            session_id         = $sid
            parent_session_id  = $psid
            role               = $role
            runtime_id         = $rid
            runtime_profile    = $rprof
            budget             = $b
            budget_source      = ([string]$snap.source)
            started_at         = $now
            deadline_at        = $now.AddSeconds([double]$wall)
            last_progress_at   = $now
            steps              = 0
            fingerprints       = New-Object System.Collections.ArrayList
            progress_flags     = New-Object System.Collections.ArrayList
            history_evicted    = 0
            process            = $procObs
            enforcement        = $null
            last_alive_proof   = $proofIso
            last_verified_tree = @()
        }
        $script:WatchdogExecutions[$tid] = $exec
        return [PSCustomObject]@{
            ok = $true; task_id = $tid; attempt_n = [int][long]$AttemptN
            budget_source = ([string]$snap.source); shadow = (-not $isEnforceGate); enforced = $isEnforceGate
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}

function Get-WatchdogExecutionEval {
    [CmdletBinding()]
    param($Execution, $Now, $Limits)
    try {
        $started = $Execution['started_at']
        $lastProg = $Execution['last_progress_at']
        $b = $Execution['budget']
        $bg = {
            param($Node, $Name)
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains($Name)) { return $Node[$Name] }
                return 0
            }
            $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
            if ($null -ne $p) { return $p.Value }
            return 0
        }
        $wall = [int](& $bg $b 'wall_clock_seconds')
        $noProg = [int](& $bg $b 'no_progress_seconds')
        $stepBudget = [int](& $bg $b 'step_budget')
        $elapsed = [int](($Now - $started).TotalSeconds)
        if ($elapsed -lt 0) { $elapsed = 0 }
        $sinceProg = [int](($Now - $lastProg).TotalSeconds)
        if ($sinceProg -lt 0) { $sinceProg = 0 }
        $steps = [int]$Execution['steps']
        $rep = Test-WatchdogRepetitionClass -Fingerprints ([string[]]@($Execution['fingerprints'])) -ProgressFlags ([bool[]]@($Execution['progress_flags'])) -SoftLimit ([int]$Limits.soft) -HardLimit ([int]$Limits.hard) -CycleLimit ([int]$Limits.cycle)
        $near = $false
        if ($wall -gt 0) {
            if (([double]$elapsed / [double]$wall) -ge [double]$script:WatchdogNearLimitRatio) { $near = $true }
        }
        if (($stepBudget -gt 0) -and (([double]$steps / [double]$stepBudget) -ge [double]$script:WatchdogNearLimitRatio)) { $near = $true }
        $classification = 'NONE'
        $wouldInterrupt = $false
        if ($elapsed -ge $wall) { $classification = 'HARD_TIMEOUT'; $wouldInterrupt = $true }
        elseif ($rep -ceq 'HARD_STALL') { $classification = 'REPEATED_ACTION'; $wouldInterrupt = $true }
        elseif ($rep -ceq 'REPEATED_CYCLE') { $classification = 'REPEATED_CYCLE'; $wouldInterrupt = $true }
        elseif ($sinceProg -ge $noProg) { $classification = 'NO_PROGRESS'; $wouldInterrupt = $true }
        elseif ($rep -ceq 'STALL_SUSPECTED') { $classification = 'STALL_SUSPECTED'; $wouldInterrupt = $false }
        elseif ($near) { $classification = 'BUDGET_NEAR_LIMIT'; $wouldInterrupt = $false }
        return [PSCustomObject]@{
            classification = $classification; would_interrupt = [bool]$wouldInterrupt
            repetition = $rep; elapsed_s = $elapsed; since_progress_s = $sinceProg
            steps = $steps; near_limit = [bool]$near
        }
    }
    catch {
        return [PSCustomObject]@{
            classification = 'NONE'; would_interrupt = $false; repetition = 'NONE'
            elapsed_s = 0; since_progress_s = 0; steps = 0; near_limit = $false
        }
    }
}

function Add-OrchestrationWatchdogAction {
    <#
    .SYNOPSIS
        Records one observed tool action: stores the sanitized
        fingerprint, advances steps, refreshes the progress clock when
        -HasProgress, evaluates, and emits telemetry with the main event
        derived from the evaluation classification. Required -AttemptN /
        -SessionId bind the observation to the registered identity:
        absent, partial, malformed or divergent identity returns
        INVALID_ATTEMPT / INVALID_SESSION_ID / IDENTITY_CONFLICT without
        mutating state. Under gate SHADOW nothing is ever interrupted.
        Under gate ENFORCE (Phase 26) an interrupting evaluation on an
        execution WITH a verified process binding runs the bounded safe
        interrupt (ownership re-verified, settlement recorded); without a
        process binding the result stays advisory-only
        (WATCHDOG_NO_PROCESS_IDENTITY) and nothing is killed. Never
        throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Tool,
        [string]$Arguments = '',
        [string]$Target = '',
        [string]$ResultClass = '',
        [bool]$HasProgress = $false,
        $AtUtc = $null,
        $AttemptN = $null,
        [string]$SessionId = '',
        [string]$PolicyPath = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $gate = Get-WatchdogGate -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
        $isEnforceGate = ($gate -ceq 'ENFORCE')
        $tid = ([string]$TaskId).Trim()
        if (-not $script:WatchdogExecutions.ContainsKey($tid)) {
            return (New-WatchdogError -Code 'NOT_REGISTERED')
        }
        $exec = $script:WatchdogExecutions[$tid]
        if (-not (Test-WatchdogAttemptN -Value $AttemptN)) { return (New-WatchdogError -Code 'INVALID_ATTEMPT') }
        if ([int][long]$AttemptN -ne [int]$exec['attempt_n']) {
            return (New-WatchdogError -Code 'IDENTITY_CONFLICT')
        }
        $obsSid = ([string]$SessionId).Trim()
        if (-not (Test-WatchdogId -Value $obsSid)) { return (New-WatchdogError -Code 'INVALID_SESSION_ID') }
        if ($obsSid -cne [string]$exec['session_id']) {
            return (New-WatchdogError -Code 'IDENTITY_CONFLICT')
        }
        $fp = Get-WatchdogActionFingerprint -Tool ([string]$Tool) -Arguments ([string]$Arguments) -Target ([string]$Target) -ResultClass ([string]$ResultClass)
        if ([string]::IsNullOrWhiteSpace($fp)) { return (New-WatchdogError -Code 'INVALID_ACTION') }
        $now = Get-WatchdogUtcNow -AtUtc $AtUtc
        [void]$exec['fingerprints'].Add($fp)
        [void]$exec['progress_flags'].Add([bool]$HasProgress)
        while ($exec['fingerprints'].Count -gt [int]$script:WatchdogHistoryCap) {
            $exec['fingerprints'].RemoveAt(0)
            $exec['progress_flags'].RemoveAt(0)
            $exec['history_evicted'] = ([int]$exec['history_evicted'] + 1)
        }
        $exec['steps'] = ([int]$exec['steps'] + 1)
        if ([bool]$HasProgress) { $exec['last_progress_at'] = $now }
        $lim = Get-WatchdogLoopLimits -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$lim.ok) { return $lim }
        $eval = Get-WatchdogExecutionEval -Execution $exec -Now $now -Limits $lim
        $events = New-Object System.Collections.ArrayList
        $emit = {
            param($Name, $Cls, $Would, $AsEnforce = $false)
            $w = Write-WatchdogTelemetryEvent -EventName $Name -TaskId $tid -AttemptN ([int]$exec['attempt_n']) -Class $Cls -WouldInterrupt ([bool]$Would) -Steps ([int]$exec['steps']) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce:([bool]$AsEnforce)
            [void]$events.Add([PSCustomObject]@{ event = $Name; class = $Cls; written = [bool]$w.ok })
        }
        if ([string]$eval.classification -ceq 'HARD_TIMEOUT') {
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'HARD_TIMEOUT' $true $isEnforceGate
            if (([string]$eval.repetition -ceq 'HARD_STALL') -or ([string]$eval.repetition -ceq 'STALL_SUSPECTED')) {
                & $emit 'REPEATED_ACTION_SUSPECTED' 'REPEATED_ACTION' $true
            }
            elseif ([string]$eval.repetition -ceq 'REPEATED_CYCLE') {
                & $emit 'WATCHDOG_WOULD_INTERRUPT' 'REPEATED_CYCLE' $true $isEnforceGate
            }
        }
        elseif ([string]$eval.classification -ceq 'REPEATED_ACTION') {
            & $emit 'REPEATED_ACTION_SUSPECTED' 'REPEATED_ACTION' $true
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'REPEATED_ACTION' $true $isEnforceGate
        }
        elseif ([string]$eval.classification -ceq 'REPEATED_CYCLE') {
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'REPEATED_CYCLE' $true $isEnforceGate
        }
        elseif ([string]$eval.classification -ceq 'NO_PROGRESS') {
            & $emit 'NO_PROGRESS_SUSPECTED' 'NO_PROGRESS' $true
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'NO_PROGRESS' $true $isEnforceGate
        }
        elseif ([string]$eval.classification -ceq 'STALL_SUSPECTED') {
            & $emit 'STALL_SUSPECTED' 'STALL_SUSPECTED' $false
        }
        if ([bool]$eval.near_limit) {
            & $emit 'BUDGET_NEAR_LIMIT' 'BUDGET_NEAR_LIMIT' $false
        }
        $enfResult = $null
        $wasInterrupted = $false
        if ([bool]$isEnforceGate) {
            $enfResult = Invoke-WatchdogEnforcement -TaskId $tid -Execution $exec -Eval $eval -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
            if ($null -ne $enfResult) {
                try { $wasInterrupted = [bool]$enfResult.interrupted } catch { $wasInterrupted = $false }
            }
        }
        return [PSCustomObject]@{
            ok = $true; task_id = $tid; steps = ([int]$exec['steps'])
            classification = ([string]$eval.classification)
            would_interrupt = ([bool]$eval.would_interrupt)
            shadow = (-not [bool]$isEnforceGate); enforced = ([bool]$isEnforceGate); interrupted = $wasInterrupted
            enforcement = $enfResult
            events = ([object[]]$events.ToArray())
            history_evicted = ([int]$exec['history_evicted'])
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}

function Get-OrchestrationWatchdogEvaluation {
    <#
    .SYNOPSIS
        Evaluation of a registered execution at a given clock. Under
        gate SHADOW it emits sanitized shadow telemetry
        (WATCHDOG_WOULD_INTERRUPT with the evaluation classification)
        when the classification is HARD_TIMEOUT or NO_PROGRESS, so a
        silent hang still leaves an event. Records nothing else: no
        fingerprint, no clock change, no interrupt, no task record.
        Under gate ENFORCE (Phase 26) any interrupting evaluation on an
        execution WITH a verified process binding runs the bounded safe
        interrupt instead (ownership re-verified, settlement recorded);
        without a process binding it stays advisory-only
        (WATCHDOG_NO_PROCESS_IDENTITY). With -IncludeEnforcement the
        queryable settlement state is attached. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        $AtUtc = $null,
        [string]$PolicyPath = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = '',
        [switch]$IncludeEnforcement
    )
    try {
        $gate = Get-WatchdogGate -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
        $isEnforceGate = ($gate -ceq 'ENFORCE')
        $tid = ([string]$TaskId).Trim()
        if (-not $script:WatchdogExecutions.ContainsKey($tid)) {
            return (New-WatchdogError -Code 'NOT_REGISTERED')
        }
        $lim = Get-WatchdogLoopLimits -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$lim.ok) { return $lim }
        $now = Get-WatchdogUtcNow -AtUtc $AtUtc
        $execRef = $script:WatchdogExecutions[$tid]
        $eval = Get-WatchdogExecutionEval -Execution $execRef -Now $now -Limits $lim
        $events = New-Object System.Collections.ArrayList
        $cls = ([string]$eval.classification)
        if ([bool]$isEnforceGate) {
            if ([bool]$eval.would_interrupt) {
                $wMain = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_WOULD_INTERRUPT' -TaskId $tid -AttemptN ([int]$execRef['attempt_n']) -Class $cls -WouldInterrupt $true -Steps ([int]$eval.steps) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot -Enforce
                [void]$events.Add([PSCustomObject]@{ event = 'WATCHDOG_WOULD_INTERRUPT'; class = $cls; written = [bool]$wMain.ok })
                if ($cls -ceq 'NO_PROGRESS') {
                    $wSec = Write-WatchdogTelemetryEvent -EventName 'NO_PROGRESS_SUSPECTED' -TaskId $tid -AttemptN ([int]$execRef['attempt_n']) -Class $cls -WouldInterrupt $true -Steps ([int]$eval.steps) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
                    [void]$events.Add([PSCustomObject]@{ event = 'NO_PROGRESS_SUSPECTED'; class = $cls; written = [bool]$wSec.ok })
                }
            }
        }
        elseif (($cls -ceq 'HARD_TIMEOUT') -or ($cls -ceq 'NO_PROGRESS')) {
            $wMain = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_WOULD_INTERRUPT' -TaskId $tid -AttemptN ([int]$execRef['attempt_n']) -Class $cls -WouldInterrupt $true -Steps ([int]$eval.steps) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
            [void]$events.Add([PSCustomObject]@{ event = 'WATCHDOG_WOULD_INTERRUPT'; class = $cls; written = [bool]$wMain.ok })
            if ($cls -ceq 'NO_PROGRESS') {
                $wSec = Write-WatchdogTelemetryEvent -EventName 'NO_PROGRESS_SUSPECTED' -TaskId $tid -AttemptN ([int]$execRef['attempt_n']) -Class $cls -WouldInterrupt $true -Steps ([int]$eval.steps) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
                [void]$events.Add([PSCustomObject]@{ event = 'NO_PROGRESS_SUSPECTED'; class = $cls; written = [bool]$wSec.ok })
            }
        }
        $enfResult = $null
        $wasInterrupted = $false
        if ([bool]$isEnforceGate) {
            $enfResult = Invoke-WatchdogEnforcement -TaskId $tid -Execution $execRef -Eval $eval -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
            if ($null -ne $enfResult) {
                try { $wasInterrupted = [bool]$enfResult.interrupted } catch { $wasInterrupted = $false }
            }
        }
        $settlement = $null
        if ([bool]$IncludeEnforcement) {
            $settlement = Get-OrchestrationWatchdogSettlement -TaskId $tid -FlagsPath $FlagsPath -RepoRoot $RepoRoot -TelemetryRoot $TelemetryRoot
        }
        return [PSCustomObject]@{
            ok = $true; task_id = $tid
            classification = ([string]$eval.classification)
            would_interrupt = ([bool]$eval.would_interrupt)
            repetition = ([string]$eval.repetition)
            elapsed_s = ([int]$eval.elapsed_s)
            since_progress_s = ([int]$eval.since_progress_s)
            steps = ([int]$eval.steps)
            near_limit = ([bool]$eval.near_limit)
            shadow = (-not [bool]$isEnforceGate); enforced = ([bool]$isEnforceGate); interrupted = $wasInterrupted
            enforcement = $enfResult; settlement = $settlement
            events = ([object[]]$events.ToArray())
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}
