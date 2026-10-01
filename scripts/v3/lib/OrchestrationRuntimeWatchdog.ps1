<#!
.SYNOPSIS
    V3 Runtime Watchdog: shadow supervision of active executions (Phase 25).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the SHADOW
    watchdog from the V3.1 runtime-reliability addendum (SPEC Part A
    sections 4-7, PLAN Phase 25):

      - Register-OrchestrationWatchdogExecution: binds task_id + attempt_n
        + session_id + parent session + role + runtime/profile to a budget
        snapshot resolved through OrchestrationExecutionBudget (role or
        profile; explicit -Budget validated, never caller-widened here).
        Closed-charset id validation reused from the budget/kernel
        convention (lowercase [a-z0-9._-], 3-64 chars).
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
      - Shadow posture: emits sanitized telemetry events
        (STALL_SUSPECTED, WATCHDOG_WOULD_INTERRUPT + class,
        BUDGET_NEAR_LIMIT, NO_PROGRESS_SUSPECTED,
        REPEATED_ACTION_SUSPECTED) to a bounded JSONL file. NEVER
        interrupts a process/session, NEVER writes task records
        (read-only over tasks; the kernel is not even dot-sourced).
      - Flag seam (read-only): watchdog{enabled,shadow} from -FlagsPath
        (default source/registry/capability-flags.json). enabled=false +
        shadow=false (or node missing) => WATCHDOG_DISABLED, no effect.
        enabled=false + shadow=true => shadow telemetry only.
        enabled=true => WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED (honest HOLD:
        real interrupt is Phase 26). This file never writes flags.
      - Bounded: per-execution fingerprint history capped at 256 entries
        (oldest evicted, counter kept); telemetry file rotation cap
        (1 MB per daily file, check+append under an exclusive lock,
        fail-closed: accounting failure or overflow refuses the write);
        clock is UTC (Get-Date).ToUniversalTime() unless -AtUtc
        overrides (tests).

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

$script:WatchdogExecutions = @{}
$script:WatchdogHistoryCap = 256
$script:WatchdogTelemetryCapBytes = 1048576
$script:WatchdogNearLimitRatio = 0.8
$script:WatchdogTelemetryLock = New-Object Object
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

function Get-WatchdogTelemetryFile {
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot)
    try {
        $dir = $TelemetryRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $repo = Get-WatchdogRepoRoot -RepoRoot $RepoRoot
            $dir = Join-Path $repo 'cache\v3\telemetry'
        }
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $dir ('watchdog-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Write-WatchdogTelemetryEvent {
    <#
    .SYNOPSIS
        Appends one sanitized shadow event (hashed ids, closed event
        tokens, small ints/bools only; never raw args/values) to the
        daily watchdog JSONL. Check (pre-size accounting) + append run
        atomically under an exclusive in-process lock (Monitor on a
        script-scope object; PS 5.1 compatible, released in finally).
        Fail-closed: mkdir failure, accounting failure (size unreadable
        or fault-injection seam $script:WatchdogSimulateAccountingFailure
        set for tests) or overflow all refuse the write with a skipped
        code; the file never exceeds the 1 MB rotation cap.
        Returns @{ok, skipped}. Never throws, never blocks.
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
        [string]$RepoRoot = ''
    )
    try {
        $allowed = @('STALL_SUSPECTED', 'WATCHDOG_WOULD_INTERRUPT', 'BUDGET_NEAR_LIMIT', 'NO_PROGRESS_SUSPECTED', 'REPEATED_ACTION_SUSPECTED')
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
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 4 -Compress) }
        catch { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        $target = Get-WatchdogTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($target)) { return [PSCustomObject]@{ ok = $false; skipped = 'no-target' } }
        $lockTaken = $false
        try {
            [System.Threading.Monitor]::Enter($script:WatchdogTelemetryLock, [ref]$lockTaken)
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
            try {
                [IO.File]::AppendAllText($target, ($text + "`n"), [Text.UTF8Encoding]::new($false))
                return [PSCustomObject]@{ ok = $true; skipped = '' }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'write' } }
        }
        finally {
            if ($lockTaken) {
                try { [System.Threading.Monitor]::Exit($script:WatchdogTelemetryLock) } catch { }
            }
        }
    }
    catch { return [PSCustomObject]@{ ok = $false; skipped = 'internal' } }
}

# ---------- execution table (in-memory only; never task records) ----------

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
        Registers an active execution for shadow supervision. Resolves and
        snapshots the canonical budget (explicit object or role/profile via
        the budget lib). Read-only over task records: state lives only in
        this module's in-memory table. Identity rule (documented): the
        key is task_id bound to (attempt_n, session_id). Re-registering
        the SAME identity is idempotent (clock and history preserved);
        a DIFFERENT identity on the same task_id returns
        IDENTITY_CONFLICT without mutating state. Never throws.
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
        [string]$RepoRoot = ''
    )
    try {
        $gate = Get-WatchdogGate -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ($gate -ceq 'ENFORCE') { return (New-WatchdogError -Code 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') }
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
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
        if ($script:WatchdogExecutions.ContainsKey($tid)) {
            $prev = $script:WatchdogExecutions[$tid]
            if (([int]$prev['attempt_n'] -eq [int][long]$AttemptN) -and ([string]$prev['session_id'] -ceq $sid)) {
                return [PSCustomObject]@{
                    ok = $true; task_id = $tid; attempt_n = [int]$prev['attempt_n']
                    budget_source = ([string]$prev['budget_source']); shadow = $true; idempotent = $true
                }
            }
            return (New-WatchdogError -Code 'IDENTITY_CONFLICT')
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
        }
        $script:WatchdogExecutions[$tid] = $exec
        return [PSCustomObject]@{
            ok = $true; task_id = $tid; attempt_n = [int][long]$AttemptN
            budget_source = ([string]$snap.source); shadow = $true
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
        Records one observed tool action (shadow only): stores the
        sanitized fingerprint, advances steps, refreshes the progress
        clock when -HasProgress, evaluates, and emits shadow telemetry
        with the main event derived from the evaluation classification.
        Required -AttemptN / -SessionId bind the observation to the
        registered identity: absent, partial, malformed or divergent
        identity returns INVALID_ATTEMPT / INVALID_SESSION_ID /
        IDENTITY_CONFLICT without mutating state. Never interrupts
        anything. Never throws.
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
        if ($gate -ceq 'ENFORCE') { return (New-WatchdogError -Code 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') }
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
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
            param($Name, $Cls, $Would)
            $w = Write-WatchdogTelemetryEvent -EventName $Name -TaskId $tid -AttemptN ([int]$exec['attempt_n']) -Class $Cls -WouldInterrupt ([bool]$Would) -Steps ([int]$exec['steps']) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
            [void]$events.Add([PSCustomObject]@{ event = $Name; class = $Cls; written = [bool]$w.ok })
        }
        if ([string]$eval.classification -ceq 'HARD_TIMEOUT') {
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'HARD_TIMEOUT' $true
            if (([string]$eval.repetition -ceq 'HARD_STALL') -or ([string]$eval.repetition -ceq 'STALL_SUSPECTED')) {
                & $emit 'REPEATED_ACTION_SUSPECTED' 'REPEATED_ACTION' $true
            }
            elseif ([string]$eval.repetition -ceq 'REPEATED_CYCLE') {
                & $emit 'WATCHDOG_WOULD_INTERRUPT' 'REPEATED_CYCLE' $true
            }
        }
        elseif ([string]$eval.classification -ceq 'REPEATED_ACTION') {
            & $emit 'REPEATED_ACTION_SUSPECTED' 'REPEATED_ACTION' $true
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'REPEATED_ACTION' $true
        }
        elseif ([string]$eval.classification -ceq 'REPEATED_CYCLE') {
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'REPEATED_CYCLE' $true
        }
        elseif ([string]$eval.classification -ceq 'NO_PROGRESS') {
            & $emit 'NO_PROGRESS_SUSPECTED' 'NO_PROGRESS' $true
            & $emit 'WATCHDOG_WOULD_INTERRUPT' 'NO_PROGRESS' $true
        }
        elseif ([string]$eval.classification -ceq 'STALL_SUSPECTED') {
            & $emit 'STALL_SUSPECTED' 'STALL_SUSPECTED' $false
        }
        if ([bool]$eval.near_limit) {
            & $emit 'BUDGET_NEAR_LIMIT' 'BUDGET_NEAR_LIMIT' $false
        }
        return [PSCustomObject]@{
            ok = $true; task_id = $tid; steps = ([int]$exec['steps'])
            classification = ([string]$eval.classification)
            would_interrupt = ([bool]$eval.would_interrupt)
            shadow = $true; interrupted = $false
            events = ([object[]]$events.ToArray())
            history_evicted = ([int]$exec['history_evicted'])
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}

function Get-OrchestrationWatchdogEvaluation {
    <#
    .SYNOPSIS
        Evaluation of a registered execution at a given clock. Emits
        sanitized shadow telemetry (WATCHDOG_WOULD_INTERRUPT with the
        evaluation classification) when the classification is
        HARD_TIMEOUT or NO_PROGRESS, so a silent hang still leaves an
        event. Records nothing else: no fingerprint, no clock change,
        no interrupt, no task record. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        $AtUtc = $null,
        [string]$PolicyPath = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $gate = Get-WatchdogGate -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if ($gate -ceq 'ENFORCE') { return (New-WatchdogError -Code 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') }
        if ($gate -ceq 'DISABLED') { return (New-WatchdogError -Code 'WATCHDOG_DISABLED') }
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
        if (($cls -ceq 'HARD_TIMEOUT') -or ($cls -ceq 'NO_PROGRESS')) {
            $wMain = Write-WatchdogTelemetryEvent -EventName 'WATCHDOG_WOULD_INTERRUPT' -TaskId $tid -AttemptN ([int]$execRef['attempt_n']) -Class $cls -WouldInterrupt $true -Steps ([int]$eval.steps) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
            [void]$events.Add([PSCustomObject]@{ event = 'WATCHDOG_WOULD_INTERRUPT'; class = $cls; written = [bool]$wMain.ok })
            if ($cls -ceq 'NO_PROGRESS') {
                $wSec = Write-WatchdogTelemetryEvent -EventName 'NO_PROGRESS_SUSPECTED' -TaskId $tid -AttemptN ([int]$execRef['attempt_n']) -Class $cls -WouldInterrupt $true -Steps ([int]$eval.steps) -ElapsedSeconds ([int]$eval.elapsed_s) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
                [void]$events.Add([PSCustomObject]@{ event = 'NO_PROGRESS_SUSPECTED'; class = $cls; written = [bool]$wSec.ok })
            }
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
            shadow = $true; interrupted = $false
            events = ([object[]]$events.ToArray())
        }
    }
    catch { return (New-WatchdogError -Code 'INTERNAL_ERROR') }
}
