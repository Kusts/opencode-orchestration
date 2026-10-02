<#!
.SYNOPSIS
    V3 Orchestration evolution + eval loop, kernel side (Phase 41 slice 1).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the
    observational evolution/eval loop from the V3.1 runtime-reliability
    addendum (PLAN Phase 41 / addendum section 18 tasks 1-10), WITHOUT any
    automatic path into production:

      - Central policy file source/registry/evolution-policy.json
        (version 1): min_sample_threshold, min_distinct_refs, declared eval
        targets (numerator/denominator counters + direction),
        shadow_comparison_tolerance, promotion_requires {review_marker,
        shadow_comparison verdict}, eval sample floor and caps. No threshold
        or tolerance is a literal in this file: an absent/malformed policy
        fails closed (EVOLUTION_POLICY_UNAVAILABLE / EVOLUTION_POLICY_INVALID)
        and never falls back to an in-code default.
      - Get-OrchestrationEvolutionSignals: deterministic aggregation of the
        declared targets from sanitized telemetry JSONL (or from injected
        fixtures for offline runs). Rates are sum(numerator)/sum(denominator)
        over bounded, strictly-typed integer counters; a target with no
        denominator data is reported as no-data (never 0, never guessed).
        Output is bounded (files/records/line bytes/counter value caps),
        order-stable (ordinal file sort, policy target order) and carries a
        signals_hash16 over the aggregated values only. Telemetry is read
        INCREMENTALLY under an explicit load budget (per-file bytes +
        every line examined, valid or not): exceeding either budget returns
        EVOLUTION_TELEMETRY_BUDGET_EXCEEDED instead of a partial result.
      - New-OrchestrationEvolutionCandidate: builds an EVOLUTION_CANDIDATE
        record (problem, repeated evidence refs, generalized cause, proposed
        change, expected effect, risk, rollback plan). Accepted ONLY when
        sample_count >= min_sample_threshold AND distinct refs >=
        min_distinct_refs (addendum 18.3: one anecdote does not produce a
        promotable rule). Below threshold nothing is written and a structured
        rejected-threshold result is returned.
      - Invoke-OrchestrationEvolutionEval: offline/replay comparison of
        baseline vs candidate (optional shadow variant) fixtures. Verdict is
        pass | regression | inconclusive, computed from the per-target deltas
        against shadow_comparison_tolerance, the declared direction, the
        sample floor and require_no_regression. 'pass' requires FULL target
        coverage: comparing a subset of the declared targets is
        'inconclusive', so a regression in an unmeasured target cannot hide
        behind a better measured one. A candidate regression is reported as
        such and blocks promotion at the promotion gate.
      - Approve-OrchestrationEvolutionCandidate: EXPLICIT promotion decision
        only. Requires the candidate record re-read and re-validated INSIDE
        the store lock (never from a pre-lock read), a review marker (when
        promotion_requires.review_marker), an eval verdict equal to the
        required shadow_comparison verdict, and one-at-a-time promotion (a
        change already promoted and not rolled back blocks a second one).
        The store is bounded: creation is rejected at the candidate-file cap
        (EVOLUTION_STORE_CANDIDATE_LIMIT) and a promotion over an incomplete
        enumeration fails closed (EVOLUTION_ENUMERATION_INCOMPLETE).
      - Rollback-OrchestrationEvolutionCandidate: explicit rollback decision
        with a mandatory reason; restores the previous (pre-promotion) state
        marker and records it.
      - History: created / promoted / rolled_back events (with reason) are
        appended to a bounded JSONL under an exclusive store lock, fail-closed
        on cap overflow. A record that cannot be audited (history append
        failed) is rolled back, and an unverifiable rollback locks the store
        (EVOLUTION_STORE_LOCKED) until an operator intervenes. Candidate
        records are content-addressed and idempotent on identical immutable
        content (wall-clock markers are excluded from the comparison).
      - Nothing automatic (addendum 18.6/18.7): this library never writes
        production policy, capability flags, source or task records. Promotion
        is a recorded decision; applying the change stays the normal
        reviewed-code flow.

    PowerShell 5.1 compatible. ASCII-only. No process, no network.
    Expected domain errors are returned as result objects
    ({ok=$false, error='CODE'} or a structured rejection), never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Safety ceilings. Policy caps may only tighten these, never widen them.
$script:EvolutionHardCapHistoryBytes = 1048576
$script:EvolutionHardCapRecordBytes = 32768
$script:EvolutionHardCapTelemetryFileBytes = 33554432
$script:EvolutionHardCapLockTimeoutMs = 2000

# ---------- repo / path helpers ----------

function Get-EvolutionRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
        return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    }
    catch { return '' }
}

function Get-EvolutionDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        $root = Get-EvolutionRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return '' }
        return (Join-Path $root 'source\registry\evolution-policy.json')
    }
    catch { return '' }
}

function Get-EvolutionDefaultStoreDir {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        $root = Get-EvolutionRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return '' }
        return (Join-Path $root 'cache\v3\evolution')
    }
    catch { return '' }
}

# ---------- result / value helpers ----------

function New-EvolutionError {
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

function ConvertTo-EvolutionOrdered {
    [CmdletBinding()]
    param($Node)
    try {
        if ($null -eq $Node) { return $null }
        if ($Node -is [string]) { return [string]$Node }
        if ($Node -is [bool]) { return [bool]$Node }
        if ($Node -is [System.Collections.IDictionary]) {
            $o = [ordered]@{}
            foreach ($k in @($Node.Keys)) { $o[[string]$k] = (ConvertTo-EvolutionOrdered -Node $Node[$k]) }
            return $o
        }
        if ($Node -is [System.ValueType]) { return $Node }
        if ($Node -is [System.Collections.IEnumerable]) {
            $a = @()
            foreach ($e in $Node) { $a += ,(ConvertTo-EvolutionOrdered -Node $e) }
            return ,$a
        }
        $o = [ordered]@{}
        foreach ($p in @($Node.PSObject.Properties)) { $o[$p.Name] = (ConvertTo-EvolutionOrdered -Node $p.Value) }
        return $o
    }
    catch { return $null }
}

function Get-EvolutionValue {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            foreach ($k in @($Object.Keys)) { if (([string]$k) -eq $Name) { return $Object[$k] } }
            return $Default
        }
        foreach ($p in @($Object.PSObject.Properties)) { if ($p.Name -eq $Name) { return $p.Value } }
        return $Default
    }
    catch { return $Default }
}

# ---------- shared sanitization ----------

function Get-EvolutionSafeText {
    <#
    .SYNOPSIS
        Shared sanitization seam (same semantics as the evidence store and
        the watchdog field redaction): secret-bearing values, token/secret
        assignments, sk- canaries and hostnames are redacted case
        insensitively, then the text is length-capped. When the
        CapabilitySanitize lib is loaded, its Get-SecretValuePattern is
        applied too (same seam OrchestrationRuntimeWatchdog uses). Raw
        values never survive this function. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value, [int]$MaxLength = 240)
    try {
        if ($null -eq $Value) { return '' }
        $s = [string]$Value
        $s = $s -replace '(?i)JEV_API_KEY\s*[=:\s]+[^\s|]+', 'JEV_API_KEY=[REDACTED]'
        $s = $s -replace '(?i)(token|api[_-]?key|secret|password|credential)\s*[=:]\s*[^\s|]+', '$1=[REDACTED]'
        $s = $s -replace '(?i)sk-[A-Za-z0-9\-_]+', '[REDACTED]'
        $s = $s -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b', '[REDACTED-HOST]'
        try {
            if ((Get-Command Get-SecretValuePattern -ErrorAction SilentlyContinue) -ne $null) {
                $pat = (Get-SecretValuePattern)
                if (-not [string]::IsNullOrWhiteSpace([string]$pat)) {
                    $s = ([regex]::Replace($s, [string]$pat, '[REDACTED]'))
                }
            }
        }
        catch { }
        if ($MaxLength -lt 1) { $MaxLength = 240 }
        $s = ($s -replace '[\r\n\t]', ' ')
        if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength) }
        return $s
    }
    catch { return '' }
}

function Test-EvolutionSafeRef {
    <#
    .SYNOPSIS
        Closed charset for an evidence reference after sanitization:
        [A-Za-z0-9._:/-] with an optional drive-letter backslash form.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:]{1,16}\\[A-Za-z0-9._:\\\\-]{1,96}$' -or $v -cmatch '^[A-Za-z0-9._:/-]{1,128}$')
    }
    catch { return $false }
}

function Get-EvolutionHashHex {
    [CmdletBinding()]
    param([string]$Text, [int]$Length = 32)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text)) }
        finally { try { $sha.Dispose() } catch { } }
        $hex = ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
        if ($Length -lt 4) { $Length = 4 }
        if ($Length -gt $hex.Length) { $Length = $hex.Length }
        return $hex.Substring(0, $Length)
    }
    catch { return '' }
}

function Get-EvolutionInvariantText {
    <#
    .SYNOPSIS
        Deterministic, culture-independent numeric text (fixed notation,
        no exponent). Used for hashing, JSON and delta comparison.
        Never throws.
    #>
    [CmdletBinding()]
    param($Value, [int]$Digits = 6)
    try {
        if ($null -eq $Value) { return '' }
        $d = $Value
        if ($d -is [bool]) { $d = 0 }
        if ($d -is [string]) {
            $parsed = 0.0
            if (-not [double]::TryParse([string]$d, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return '' }
            $d = $parsed
        }
        $dbl = [double]$d
        if ([double]::IsNaN($dbl) -or [double]::IsInfinity($dbl)) { return '' }
        if ($Digits -lt 0) { $Digits = 0 }
        if ($Digits -gt 12) { $Digits = 12 }
        return ($dbl.ToString(('0.' + ('0' * $Digits)), [Globalization.CultureInfo]::InvariantCulture))
    }
    catch { return '' }
}

function Test-EvolutionStrictInt {
    <#
    .SYNOPSIS
        Strict integer check: only [int]/[long] in [Min, Max]; bool,
        string, double/decimal are rejected by type. Never throws.
    #>
    [CmdletBinding()]
    param($Value, [int]$Min = 0, [int]$Max = 2147483647)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]))) { return $false }
        $n = [long]$Value
        return (($n -ge [long]$Min) -and ($n -le [long]$Max))
    }
    catch { return $false }
}

function Test-EvolutionCandidateId {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        return ($v -cmatch '^evc-[0-9a-f]{16}$')
    }
    catch { return $false }
}

function Get-EvolutionUtcNowText {
    <#
    .SYNOPSIS
        UTC clock as an ISO-8601 'o' string. -AtUtc (DateTime/DateTimeOffset/
        string) overrides for tests, so every timestamp is a value, not a
        side effect. Never throws.
    #>
    [CmdletBinding()]
    param($AtUtc)
    try {
        if ($null -ne $AtUtc) {
            if ($AtUtc -is [DateTime]) { return (([DateTime]$AtUtc).ToUniversalTime().ToString('o')) }
            if ($AtUtc -is [DateTimeOffset]) { return (([DateTimeOffset]$AtUtc).UtcDateTime.ToString('o')) }
            $s = ([string]$AtUtc).Trim()
            if (-not [string]::IsNullOrWhiteSpace($s)) {
                $dto = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dto)) {
                    return ($dto.UtcDateTime.ToString('o'))
                }
            }
        }
    }
    catch { return '' }
    try { return ([DateTime]::UtcNow.ToString('o')) }
    catch { return '1970-01-01T00:00:00.0000000Z' }
}

# ---------- policy (central, fail-closed) ----------

function Read-EvolutionPolicy {
    <#
    .SYNOPSIS
        Reads the central policy file. Returns @{found, malformed, doc}.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    $out = @{ found = $false; malformed = $false; doc = $null }
    try {
        $p = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-EvolutionDefaultPolicyPath -RepoRoot $RepoRoot }
        if ([string]::IsNullOrWhiteSpace($p)) { return $out }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $out.found = $true
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        $rec = ConvertTo-EvolutionOrdered -Node $doc
        if ($null -eq $rec -or -not ($rec -is [System.Collections.IDictionary])) { $out.malformed = $true; return $out }
        $out.doc = $rec
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Get-EvolutionTargetSpec {
    <#
    .SYNOPSIS
        Projects the declared eval targets. STRICT: nothing is skipped,
        defaulted or substituted. A single malformed entry (blank/illegal
        id, missing or illegal numerator/denominator, missing/unknown
        direction, duplicate id) invalidates the WHOLE target list, which
        yields an empty projection so Test-EvolutionPolicyShape fails closed
        with EVOLUTION_POLICY_INVALID. A partially usable policy is never
        silently accepted (V1).
    #>
    [CmdletBinding()]
    param($Policy)
    $out = New-Object System.Collections.ArrayList
    try {
        $raw = @(Get-EvolutionValue $Policy 'eval_targets' @())
        if ($raw.Count -eq 0) { return @() }
        $seen = @{}
        foreach ($t in $raw) {
            $id = ([string](Get-EvolutionValue $t 'id' '')).Trim()
            $num = ([string](Get-EvolutionValue $t 'numerator' '')).Trim()
            $den = ([string](Get-EvolutionValue $t 'denominator' '')).Trim()
            $dir = ([string](Get-EvolutionValue $t 'direction' '')).Trim()
            $kind = ([string](Get-EvolutionValue $t 'kind' '')).Trim()
            if ($id -notmatch '^[a-z][a-z0-9_]{2,63}$') { return @() }
            if (($num -notmatch '^[a-z][a-z0-9_]{1,63}$') -or ($den -notmatch '^[a-z][a-z0-9_]{1,63}$')) { return @() }
            if ($dir -cnotin @('lower_is_better', 'higher_is_better')) { return @() }
            if ($kind -notmatch '^[a-z][a-z0-9_]{1,31}$') { return @() }
            if ($seen.ContainsKey($id)) { return @() }
            $seen[$id] = $true
            [void]$out.Add([PSCustomObject]@{
                    id          = $id
                    kind        = $kind
                    numerator   = $num
                    denominator = $den
                    direction   = $dir
                })
        }
        if ($out.Count -ne $raw.Count) { return @() }
    }
    catch { return @() }
    # Returned un-wrapped: every caller collects with @() so a single target
    # and an empty target set behave the same as the full set.
    return @($out.ToArray())
}

function Test-EvolutionPolicyShape {
    <#
    .SYNOPSIS
        Strict shape validation. Every threshold/tolerance is read here and
        nowhere else as a literal. Returns $false for anything malformed so
        callers fail closed. Never throws.
    #>
    [CmdletBinding()]
    param($Policy)
    try {
        if ($null -eq $Policy) { return $false }
        if (-not (Test-EvolutionStrictInt -Value (Get-EvolutionValue $Policy 'version' $null) -Min 1 -Max 1)) { return $false }
        $thr = Get-EvolutionValue $Policy 'min_sample_threshold' $null
        if (-not (Test-EvolutionStrictInt -Value $thr -Min 1 -Max 1000)) { return $false }
        if (-not (Test-EvolutionStrictInt -Value (Get-EvolutionValue $Policy 'min_distinct_refs' $null) -Min 1 -Max 1000)) { return $false }
        $tol = Get-EvolutionValue $Policy 'shadow_comparison_tolerance' $null
        # bool/string are never a tolerance; int/long/double/single/decimal
        # are (ConvertFrom-Json yields decimal for some literals).
        if (($tol -is [bool]) -or ($tol -is [string]) -or ($null -eq $tol)) { return $false }
        if (-not (($tol -is [int]) -or ($tol -is [long]) -or ($tol -is [double]) -or ($tol -is [single]) -or ($tol -is [decimal]))) { return $false }
        if (([double]$tol) -lt 0.0 -or ([double]$tol) -gt 1000.0) { return $false }
        $pr = Get-EvolutionValue $Policy 'promotion_requires' $null
        if ($null -eq $pr) { return $false }
        $marker = Get-EvolutionValue $pr 'review_marker' $null
        if (($null -eq $marker) -or (-not ($marker -is [bool]))) { return $false }
        $shadow = ([string](Get-EvolutionValue $pr 'shadow_comparison' '')).Trim()
        if ($shadow -cnotin @('pass', 'regression', 'inconclusive')) { return $false }
        $evalNode = Get-EvolutionValue $Policy 'eval' $null
        if ($null -eq $evalNode) { return $false }
        if (-not (Test-EvolutionStrictInt -Value (Get-EvolutionValue $evalNode 'min_samples_per_variant' $null) -Min 1 -Max 1000000)) { return $false }
        $noReg = Get-EvolutionValue $evalNode 'require_no_regression' $null
        if (($null -eq $noReg) -or (-not ($noReg -is [bool]))) { return $false }
        # Strict: a partially malformed target list projects to nothing, so
        # the whole policy is rejected (never repaired by substitution).
        $targets = @(Get-EvolutionTargetSpec -Policy $Policy)
        if ($targets.Count -eq 0) { return $false }
        $auth = Get-EvolutionValue $Policy 'authority' $null
        if ($null -eq $auth) { return $false }
        $auto = Get-EvolutionValue $auth 'automatic_promotion' $null
        if (($null -eq $auto) -or (-not ($auto -is [bool])) -or [bool]$auto) { return $false }
        $caps = Get-EvolutionValue $Policy 'caps' $null
        if ($null -eq $caps) { return $false }
        foreach ($name in @('max_evidence_refs', 'max_text_length', 'max_ref_length', 'max_review_marker_length', 'max_reason_length', 'max_record_bytes', 'max_history_bytes', 'max_candidate_files', 'max_telemetry_files', 'max_telemetry_records', 'max_telemetry_line_bytes', 'max_telemetry_file_bytes', 'max_metric_value', 'lock_timeout_ms')) {
            if (-not (Test-EvolutionStrictInt -Value (Get-EvolutionValue $caps $name $null) -Min 1 -Max 100000000)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-EvolutionPolicyCap {
    [CmdletBinding()]
    param($Policy, [Parameter(Mandatory = $true)][string]$Name, [int]$Fallback = 1)
    try {
        $caps = Get-EvolutionValue $Policy 'caps' $null
        $v = Get-EvolutionValue $caps $Name $null
        if (Test-EvolutionStrictInt -Value $v -Min 1 -Max 100000000) { return [int]$v }
        return [int]$Fallback
    }
    catch { return [int]$Fallback }
}

function Resolve-EvolutionPolicy {
    <#
    .SYNOPSIS
        Resolves + validates the policy once per call. Returns
        @{ok=$true; policy} or a structured error; never throws and never
        substitutes in-code defaults for a missing/invalid policy.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    try {
        $slot = Read-EvolutionPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$slot.found) { return (New-EvolutionError -Code 'EVOLUTION_POLICY_UNAVAILABLE') }
        if ([bool]$slot.malformed) { return (New-EvolutionError -Code 'EVOLUTION_POLICY_MALFORMED') }
        if (-not (Test-EvolutionPolicyShape -Policy $slot.doc)) { return (New-EvolutionError -Code 'EVOLUTION_POLICY_INVALID') }
        return [PSCustomObject]@{ ok = $true; policy = $slot.doc }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_POLICY_UNAVAILABLE') }
}

# ---------- store lock + bounded history ----------

function Enter-EvolutionStoreLock {
    <#
    .SYNOPSIS
        Exclusive store-directory lock (open .evolution.lock with
        FileShare::None), retried until the bounded timeout. Returns
        @{ok=$true; handle} or @{ok=$false; error='EVOLUTION_LOCK_BUSY'}.
        Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [int]$LockTimeoutMs = 200)
    try {
        if (-not (Test-Path -LiteralPath $StoreDir -PathType Container)) { [void][IO.Directory]::CreateDirectory($StoreDir) }
        $ms = [int]$LockTimeoutMs
        if ($ms -lt 1) { $ms = 1 }
        if ($ms -gt $script:EvolutionHardCapLockTimeoutMs) { $ms = $script:EvolutionHardCapLockTimeoutMs }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($ms)
        do {
            $handle = $null
            try {
                $handle = [IO.File]::Open((Join-Path $StoreDir '.evolution.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                return [PSCustomObject]@{ ok = $true; handle = $handle }
            }
            catch { if ($null -ne $handle) { try { $handle.Dispose() } catch { } } }
            Start-Sleep -Milliseconds 10
        } while ([DateTime]::UtcNow -lt $deadline)
        return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_LOCK_BUSY' }
    }
    catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_LOCK_UNAVAILABLE' } }
}

function Exit-EvolutionStoreLock {
    [CmdletBinding()]
    param($Lock)
    try { if ($null -ne $Lock) { $Lock.Dispose() } } catch { }
}

function Get-EvolutionStoreLockedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir)
    return (Join-Path $StoreDir '.evolution-store-locked')
}

function Test-EvolutionStoreLocked {
    <#
    .SYNOPSIS
        $true when a previous COMPOSITE failure (state restore failed after a
        history append failed) left the store in an unknown state. The marker
        is written once and every store mutation then refuses with
        EVOLUTION_STORE_LOCKED until an operator intervenes and removes it;
        nothing here auto-clears it. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir)
    try { return (Test-Path -LiteralPath (Get-EvolutionStoreLockedPath -StoreDir $StoreDir) -PathType Leaf) }
    catch { return $true }
}

function Set-EvolutionStoreLocked {
    <#
    .SYNOPSIS
        Marks the store as locked (reason recorded) after a composite
        failure. Best-effort and fail-closed: returns $false only when the
        marker itself cannot be read back. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)][string]$Reason)
    try {
        $path = Get-EvolutionStoreLockedPath -StoreDir $StoreDir
        $doc = [ordered]@{
            record_type = 'EVOLUTION_STORE_LOCK'
            reason      = (Get-EvolutionSafeText -Value $Reason -MaxLength 240)
            at          = (Get-EvolutionUtcNowText)
        }
        [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $doc -Depth 4 -Compress), [Text.UTF8Encoding]::new($false))
        return (Test-Path -LiteralPath $path -PathType Leaf)
    }
    catch { return $false }
}

function Get-EvolutionHistoryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir)
    return (Join-Path $StoreDir 'evolution-history.jsonl')
}

function Add-EvolutionHistoryEvent {
    <#
    .SYNOPSIS
        Appends one bounded history event. Caller holds the store lock.
        Fail-closed: serialization failure, size overflow or write failure
        return @{ok=$false; error=CODE} and nothing is appended (the calling
        decision is therefore NOT recorded, and the caller must roll back
        its own state change). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)]$Policy, [Parameter(Mandatory = $true)]$Event)
    try {
        $text = ''
        try { $text = (ConvertTo-Json -InputObject $Event -Depth 8 -Compress) }
        catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_SERIALIZE' } }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_SERIALIZE' } }
        $line = ($text + "`n")
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 8192) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_EVENT_TOO_LARGE' } }
        $cap = (Get-EvolutionPolicyCap -Policy $Policy -Name 'max_history_bytes' -Fallback 262144)
        if ($cap -gt $script:EvolutionHardCapHistoryBytes) { $cap = $script:EvolutionHardCapHistoryBytes }
        $path = Get-EvolutionHistoryPath -StoreDir $StoreDir
        $current = [long]0
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { $current = ([IO.FileInfo]::new($path)).Length } catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_UNREADABLE' } }
        }
        if (($current + [long][Text.Encoding]::UTF8.GetByteCount($line)) -gt [long]$cap) {
            return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_CAP' }
        }
        try {
            [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
            return [PSCustomObject]@{ ok = $true; error = '' }
        }
        catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_WRITE_FAILED' } }
    }
    catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_HISTORY_WRITE_FAILED' } }
}

function Get-OrchestrationEvolutionHistory {
    <#
    .SYNOPSIS
        Reads the bounded history JSONL (read-only, tolerant of partial or
        malformed lines). -CandidateId filters to one candidate. Returns
        @{ok, events[], count, truncated}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [string]$CandidateId, [int]$MaxEvents = 2000)
    $events = New-Object System.Collections.ArrayList
    $out = [ordered]@{ ok = $true; events = @(); count = 0; truncated = $false }
    try {
        $path = Get-EvolutionHistoryPath -StoreDir $StoreDir
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $out.events = @()
            return ([PSCustomObject]$out)
        }
        $cap = [int]$MaxEvents
        if ($cap -lt 1) { $cap = 1 }
        $lines = $null
        try { $lines = [IO.File]::ReadAllLines($path) } catch { $out.ok = $false; $out.error = 'EVOLUTION_HISTORY_UNREADABLE'; return ([PSCustomObject]$out) }
        foreach ($line in @($lines)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            if ($events.Count -ge $cap) { $out.truncated = $true; break }
            $row = $null
            try { $row = ([string]$line | ConvertFrom-Json) } catch { continue }
            if ($null -eq $row) { continue }
            $ev = ConvertTo-EvolutionOrdered -Node $row
            if ($null -eq ($ev -is [System.Collections.IDictionary])) { continue }
            if (-not [string]::IsNullOrWhiteSpace($CandidateId)) {
                if ([string](Get-EvolutionValue $ev 'candidate_id' '') -cne ([string]$CandidateId)) { continue }
            }
            [void]$events.Add([PSCustomObject]$ev)
        }
        $out.events = @($events.ToArray())
        $out.count = $out.events.Count
        return ([PSCustomObject]$out)
    }
    catch { $out.ok = $false; $out.events = @(); $out.count = 0; return ([PSCustomObject]$out) }
}

# ---------- R2: signals ----------

function Get-EvolutionTelemetryFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TelemetryDir, [int]$MaxFiles = 64)
    try {
        if (-not (Test-Path -LiteralPath $TelemetryDir -PathType Container)) { return @() }
        $all = [string[]]@([IO.Directory]::GetFiles($TelemetryDir, '*.jsonl', [IO.SearchOption]::TopDirectoryOnly))
        $list = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $all) { [void]$list.Add([string]$f) }
        $list.Sort([StringComparer]::Ordinal)
        $n = [int]$MaxFiles
        if ($n -lt 1) { $n = 1 }
        $out = @()
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($out.Count -ge $n) { break }
            $out += $list[$i]
        }
        return $out
    }
    catch { return @() }
}

function ConvertTo-EvolutionCounters {
    <#
    .SYNOPSIS
        Normalizes one telemetry record into a closed integer counter map.
        Only the counter names declared by the policy targets are read;
        unknown fields are ignored. A declared field whose value is not a
        strict in-range integer rejects the WHOLE record (no partial or
        coerced counts). Returns @{ok; counters} or @{ok=$false; reason}.
        Never throws.
    #>
    [CmdletBinding()]
    param($Record, $Policy)
    try {
        $allowed = @{}
        foreach ($t in @(Get-EvolutionTargetSpec -Policy $Policy)) {
            $allowed[[string]$t.numerator] = $true
            $allowed[[string]$t.denominator] = $true
        }
        $maxValue = (Get-EvolutionPolicyCap -Policy $Policy -Name 'max_metric_value' -Fallback 1000000)
        $counters = [ordered]@{}
        $names = @()
        if ($Record -is [System.Collections.IDictionary]) { $names = @($Record.Keys | ForEach-Object { [string]$_ }) }
        else { $names = @($Record.PSObject.Properties | ForEach-Object { [string]$_.Name }) }
        foreach ($name in $names) {
            if (-not $allowed.ContainsKey($name)) { continue }
            $raw = Get-EvolutionValue $Record $name $null
            if (-not (Test-EvolutionStrictInt -Value $raw -Min 0 -Max $maxValue)) {
                return [PSCustomObject]@{ ok = $false; reason = ('invalid-counter:' + $name) }
            }
            $counters[$name] = [int]$raw
        }
        if ($counters.Count -eq 0) { return [PSCustomObject]@{ ok = $false; reason = 'no-counters' } }
        return [PSCustomObject]@{ ok = $true; reason = ''; counters = $counters }
    }
    catch { return [PSCustomObject]@{ ok = $false; reason = 'record-unreadable' } }
}

function Get-OrchestrationEvolutionSignals {
    <#
    .SYNOPSIS
        Deterministic aggregation of the declared eval targets from
        sanitized telemetry JSONL (-TelemetryDir) or from injected record
        fixtures (-Fixtures, which take precedence and require no file).
        Bounded (files / records / line bytes / counter value), ordinal
        file order, policy target order, counters-only output (no raw field
        ever leaves this function). A target with zero denominator data is
        reported as status 'no-data' with a null value, never 0.
        Load budget (fail-closed, never a partial aggregation presented as
        complete): telemetry files are read INCREMENTALLY (one line at a
        time, never ReadAllLines/ReadAllText) under two budgets - per file
        max_telemetry_file_bytes and a global max_telemetry_records that
        counts EVERY line read, blank ones included, valid or not. Exhausting
        either budget returns EVOLUTION_TELEMETRY_BUDGET_EXCEEDED.
        Returns @{ok, generated_at, records_read, records_skipped,
        skipped_by_reason, truncated, targets[], signals_hash16}.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$TelemetryDir,
        $Fixtures,
        [string]$PolicyPath,
        [string]$RepoRoot,
        $AtUtc
    )
    try {
        $resolved = Resolve-EvolutionPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$resolved.ok) { return $resolved }
        $policy = $resolved.policy
        $maxFiles = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_telemetry_files' -Fallback 64)
        $maxRecords = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_telemetry_records' -Fallback 2000)
        $maxLineBytes = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_telemetry_line_bytes' -Fallback 4096)
        $maxFileBytes = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_telemetry_file_bytes' -Fallback 1048576)
        if ($maxFileBytes -gt $script:EvolutionHardCapTelemetryFileBytes) { $maxFileBytes = $script:EvolutionHardCapTelemetryFileBytes }
        $targets = @(Get-EvolutionTargetSpec -Policy $policy)
        $skipped = [ordered]@{}
        $records = New-Object System.Collections.ArrayList
        $truncated = $false
        $sources = 0
        # Load budget: EVERY line/record examined counts, blank ones included,
        # valid or not, so a hostile file (junk OR blank padding) cannot be
        # smuggled past the cap.
        $examined = 0
        if ($null -ne $Fixtures) {
            $sources = 1
            foreach ($fixture in @($Fixtures)) {
                $examined++
                if ($examined -gt $maxRecords) {
                    return (New-EvolutionError -Code 'EVOLUTION_TELEMETRY_BUDGET_EXCEEDED' -Extra @{ budget = 'max_telemetry_records'; limit = [int]$maxRecords })
                }
                $conv = ConvertTo-EvolutionCounters -Record $fixture -Policy $policy
                if ([bool]$conv.ok) { [void]$records.Add($conv.counters) }
                else { $key = ([string]$conv.reason); if (-not [string]::IsNullOrWhiteSpace($key)) { if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }; $skipped[$key] = ([int]$skipped[$key] + 1) } }
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($TelemetryDir)) { return (New-EvolutionError -Code 'EVOLUTION_TELEMETRY_SOURCE_REQUIRED') }
            if (-not (Test-Path -LiteralPath $TelemetryDir -PathType Container)) { return (New-EvolutionError -Code 'EVOLUTION_TELEMETRY_UNAVAILABLE') }
            $files = @(Get-EvolutionTelemetryFiles -TelemetryDir $TelemetryDir -MaxFiles $maxFiles)
            $sources = $files.Count
            if ($files.Count -ge $maxFiles) { $truncated = $true }
            foreach ($file in $files) {
                $fileBytes = [long]0
                try { $fileBytes = ([IO.FileInfo]::new($file)).Length } catch { $key = 'file-unreadable'; if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }; $skipped[$key] = ([int]$skipped[$key] + 1); continue }
                if ($fileBytes -gt [long]$maxFileBytes) {
                    return (New-EvolutionError -Code 'EVOLUTION_TELEMETRY_BUDGET_EXCEEDED' -Extra @{ budget = 'max_telemetry_file_bytes'; limit = [int]$maxFileBytes })
                }
                $reader = $null
                try { $reader = New-Object System.IO.StreamReader($file, [Text.UTF8Encoding]::new($false), $true, 4096) }
                catch { $key = 'file-unreadable'; if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }; $skipped[$key] = ([int]$skipped[$key] + 1); continue }
                try {
                    $line = $null
                    while ($null -ne ($line = $reader.ReadLine())) {
                        # FIX3: EVERY line read counts against the budget,
                        # blank ones included - otherwise a file padded with
                        # empty lines would read unbounded while "passing" a
                        # budget check that never saw those lines.
                        $examined++
                        if ($examined -gt $maxRecords) {
                            return (New-EvolutionError -Code 'EVOLUTION_TELEMETRY_BUDGET_EXCEEDED' -Extra @{ budget = 'max_telemetry_records'; limit = [int]$maxRecords })
                        }
                        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
                        if ([Text.Encoding]::UTF8.GetByteCount([string]$line) -gt $maxLineBytes) {
                            $key = 'line-too-long'
                            if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }
                            $skipped[$key] = ([int]$skipped[$key] + 1)
                            continue
                        }
                        $row = $null
                        try { $row = ([string]$line | ConvertFrom-Json) } catch { $key = 'unparsable-line'; if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }; $skipped[$key] = ([int]$skipped[$key] + 1); continue }
                        if ($null -eq $row) { $key = 'unparsable-line'; if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }; $skipped[$key] = ([int]$skipped[$key] + 1); continue }
                        $conv = ConvertTo-EvolutionCounters -Record $row -Policy $policy
                        if ([bool]$conv.ok) { [void]$records.Add($conv.counters) }
                        else { $key = ([string]$conv.reason); if (-not $skipped.Contains($key)) { $skipped[$key] = 0 }; $skipped[$key] = ([int]$skipped[$key] + 1) }
                    }
                }
                finally { try { if ($null -ne $reader) { $reader.Dispose() } } catch { } }
            }
        }
        $rows = New-Object System.Collections.ArrayList
        $hashParts = New-Object System.Collections.ArrayList
        foreach ($t in $targets) {
            [long]$num = 0
            [long]$den = 0
            $withData = 0
            foreach ($rec in @($records.ToArray())) {
                $hasNum = $rec.Contains($t.numerator)
                $hasDen = $rec.Contains($t.denominator)
                if ($hasNum) { $num = ([long]$num + [long]$rec[$t.numerator]) }
                if ($hasDen) {
                    $den = ([long]$den + [long]$rec[$t.denominator])
                    if ($hasNum) { $withData++ }
                }
            }
            $status = 'ok'
            $value = $null
            $text = ''
            if ($den -le 0) {
                $status = 'no-data'
            }
            else {
                $value = [Math]::Round(([double]$num / [double]$den), 6)
                $text = (Get-EvolutionInvariantText -Value $value -Digits 6)
            }
            [void]$rows.Add([PSCustomObject]@{
                    target      = [string]$t.id
                    direction   = [string]$t.direction
                    numerator   = [long]$num
                    denominator = [long]$den
                    value       = $value
                    value_text  = $text
                    status      = $status
                })
            [void]$hashParts.Add(([string]$t.id + '=' + $text))
        }
        $material = ($hashParts -join ';')
        return [PSCustomObject]@{
            ok                 = $true
            error              = ''
            generated_at       = (Get-EvolutionUtcNowText -AtUtc $AtUtc)
            source             = $(if ($null -ne $Fixtures) { 'fixtures' } else { 'telemetry' })
            sources            = [int]$sources
            records_read       = [int]$records.Count
            records_skipped    = [int](($skipped.Values | Measure-Object -Sum).Sum)
            skipped_by_reason  = [PSCustomObject]$skipped
            truncated          = [bool]$truncated
            targets            = @($rows.ToArray())
            signals_hash16     = (Get-EvolutionHashHex -Text $material -Length 16)
            redacted           = $true
        }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_SIGNALS_FAILED') }
}

# ---------- store helpers (candidates) ----------

function Get-EvolutionCandidateDir {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir)
    return (Join-Path $StoreDir 'candidates')
}

function Get-EvolutionCandidatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)][string]$CandidateId)
    return (Join-Path (Get-EvolutionCandidateDir -StoreDir $StoreDir) (([string]$CandidateId) + '.json'))
}

function Remove-EvolutionCandidateRecord {
    <#
    .SYNOPSIS
        Deletes one candidate record file (used only to roll back a creation
        whose history append failed, so no promotable record can exist
        without its 'created' event). Caller holds the store lock. Returns
        @{ok; removed}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)][string]$CandidateId)
    try {
        $path = Get-EvolutionCandidatePath -StoreDir $StoreDir -CandidateId $CandidateId
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [PSCustomObject]@{ ok = $true; removed = $false } }
        [IO.File]::Delete($path)
        return [PSCustomObject]@{ ok = $true; removed = (-not (Test-Path -LiteralPath $path -PathType Leaf)) }
    }
    catch { return [PSCustomObject]@{ ok = $false; removed = $false } }
}

function Get-EvolutionRecordImmutableText {
    <#
    .SYNOPSIS
        Canonical JSON of a record's IMMUTABLE content: every field except
        the volatile wall-clock markers (created_at/updated_at/promoted_at/
        rolled_back_at), sorted by key. Identity of a candidate is content,
        not the instant it happened to be materialized, so re-creating the
        same candidate later is idempotent instead of a false conflict
        (V3). Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        $rec = ConvertTo-EvolutionOrdered -Node $Record
        if (-not ($rec -is [System.Collections.IDictionary])) { return '' }
        $volatile = @('created_at', 'updated_at', 'promoted_at', 'rolled_back_at')
        $proj = [ordered]@{}
        foreach ($k in (@($rec.Keys) | Sort-Object -CaseSensitive)) {
            $name = [string]$k
            if ($volatile -ccontains $name) { continue }
            $proj[$name] = $rec[$k]
        }
        return [string](ConvertTo-Json -InputObject $proj -Depth 8 -Compress)
    }
    catch { return '' }
}

function Save-EvolutionCandidateRecord {
    <#
    .SYNOPSIS
        Writes one content-addressed candidate record. With
        -Overwrite:$false an existing record with different IMMUTABLE
        content is a conflict; identical immutable content is idempotent
        and the stored record is preserved untouched. An existing record
        larger than the hard record cap is refused with
        EVOLUTION_RECORD_TOO_LARGE BEFORE it is read (SEC-4: the comparison
        path is the only place this function reads an untrusted file).
        Caller holds the store lock. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)]$Policy, [Parameter(Mandatory = $true)]$Record, [switch]$Overwrite)
    try {
        $text = ConvertTo-Json -InputObject $Record -Depth 8 -Compress
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_SERIALIZE' } }
        $cap = (Get-EvolutionPolicyCap -Policy $Policy -Name 'max_record_bytes' -Fallback 32768)
        if ($cap -gt $script:EvolutionHardCapRecordBytes) { $cap = $script:EvolutionHardCapRecordBytes }
        if ([Text.Encoding]::UTF8.GetByteCount($text) -gt $cap) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_TOO_LARGE' } }
        $id = [string](Get-EvolutionValue $Record 'candidate_id' '')
        if (-not (Test-EvolutionCandidateId -Value $id)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_INVALID_CANDIDATE_ID' } }
        $dir = Get-EvolutionCandidateDir -StoreDir $StoreDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void][IO.Directory]::CreateDirectory($dir) }
        $path = Get-EvolutionCandidatePath -StoreDir $StoreDir -CandidateId $id
        if ((-not [bool]$Overwrite) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            # SEC-4 (idempotent-comparison path): the existing record is the
            # only UNTRUSTED file this function reads, so its size is checked
            # via FileInfo BEFORE any ReadAllText - a candidate inflated
            # outside the write path must not be pulled into memory by a
            # re-creation. Same semantics as the single-record read (FIX4).
            $existingLength = [long]-1
            try { $existingLength = ([IO.FileInfo]::new($path)).Length } catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_UNREADABLE' } }
            if ($existingLength -gt [long]$script:EvolutionHardCapRecordBytes) {
                return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_TOO_LARGE'; bytes = [long]$existingLength; cap = [int]$script:EvolutionHardCapRecordBytes }
            }
            $existing = $null
            try { $existing = [IO.File]::ReadAllText($path) } catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_UNREADABLE' } }
            $existingDoc = $null
            try { $existingDoc = ConvertTo-EvolutionOrdered -Node (($existing | ConvertFrom-Json)) } catch { $existingDoc = $null }
            $mine = Get-EvolutionRecordImmutableText -Record $Record
            if ([string]::IsNullOrWhiteSpace($mine)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_SERIALIZE' } }
            $theirs = ''
            if ($null -ne $existingDoc) { $theirs = Get-EvolutionRecordImmutableText -Record $existingDoc }
            if ([string]::IsNullOrWhiteSpace($theirs)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_CONFLICT' } }
            if ($theirs -cne $mine) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_CONFLICT' } }
            return [PSCustomObject]@{ ok = $true; error = 'idempotent' }
        }
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        return [PSCustomObject]@{ ok = $true; error = '' }
    }
    catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_RECORD_WRITE_FAILED' } }
}

function Get-OrchestrationEvolutionCandidate {
    <#
    .SYNOPSIS
        Reads one candidate record (read-only, shape-validated; the file name
        must match the embedded candidate_id). A file larger than the hard
        record cap is refused with EVOLUTION_RECORD_TOO_LARGE BEFORE it is
        read (SEC-4, same rule as the inventory), so the promotion/rollback
        gate fails closed without loading an oversized record. Returns the
        record or a structured error. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)][string]$CandidateId)
    try {
        if (-not (Test-EvolutionCandidateId -Value $CandidateId)) { return (New-EvolutionError -Code 'EVOLUTION_INVALID_CANDIDATE_ID') }
        $path = Get-EvolutionCandidatePath -StoreDir $StoreDir -CandidateId ([string]$CandidateId)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_NOT_FOUND') }
        # SEC-4 (same rule as the inventory): the size is checked via FileInfo
        # BEFORE any ReadAllText, so an oversized/corrupt record is refused
        # without ever being loaded. Promotion and rollback decide from this
        # read, so the refusal is fail-closed for both.
        $length = [long]-1
        try { $length = ([IO.FileInfo]::new($path)).Length } catch { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_UNREADABLE') }
        if ($length -gt [long]$script:EvolutionHardCapRecordBytes) {
            return (New-EvolutionError -Code 'EVOLUTION_RECORD_TOO_LARGE' -Extra @{ bytes = [long]$length; cap = [int]$script:EvolutionHardCapRecordBytes })
        }
        $text = $null
        try { $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) } catch { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_UNREADABLE') }
        $doc = ConvertTo-EvolutionOrdered -Node ($text | ConvertFrom-Json)
        if (-not ($doc -is [System.Collections.IDictionary])) { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_MALFORMED') }
        if ([int](Get-EvolutionValue $doc 'schema_version' 0) -ne 1) { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_MALFORMED') }
        if ([string](Get-EvolutionValue $doc 'record_type' '') -cne 'EVOLUTION_CANDIDATE') { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_MALFORMED') }
        if ([string](Get-EvolutionValue $doc 'candidate_id' '') -cne ([string]$CandidateId)) { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_MALFORMED') }
        $status = [string](Get-EvolutionValue $doc 'status' '')
        if ($status -cnotin @('candidate', 'promoted', 'rolled_back')) { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_MALFORMED') }
        return [PSCustomObject]@{ ok = $true; error = ''; record = [PSCustomObject]$doc }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_UNREADABLE') }
}

function Get-EvolutionCandidateInventory {
    <#
    .SYNOPSIS
        Full candidate-store inventory with an explicit completeness flag.
        @{ok; entries[]; total_files; cap; complete}. `complete` is $false
        when the store holds MORE candidate files than the policy cap (the
        window is only a prefix), OR when any file in the candidates directory
        cannot be interpreted as the candidate it claims to be: unexpected
        name, larger than the hard record cap (checked via FileInfo before any
        read, so it is never loaded), unreadable, unparsable, non-object,
        unknown status, or an embedded candidate_id that does not match the
        file name (identity). Callers that make a decision from this window
        (promotion / one-at-a-time) must fail closed on complete=$false
        instead of trusting a window that may be hiding a promoted change
        (V5/V7/FIX2/FIX3).
        Read-only. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, $Policy)
    $entries = New-Object System.Collections.ArrayList
    $out = [ordered]@{ ok = $true; entries = @(); total_files = 0; cap = 0; complete = $true }
    try {
        $cap = 200
        if ($null -ne $Policy) { $cap = (Get-EvolutionPolicyCap -Policy $Policy -Name 'max_candidate_files' -Fallback 200) }
        $out.cap = [int]$cap
        $dir = Get-EvolutionCandidateDir -StoreDir $StoreDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return ([PSCustomObject]$out) }
        $all = [string[]]@([IO.Directory]::GetFiles($dir, '*.json', [IO.SearchOption]::TopDirectoryOnly))
        $list = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $all) { [void]$list.Add([string]$f) }
        $list.Sort([StringComparer]::Ordinal)
        $out.total_files = [int]$list.Count
        # More files than the cap: the window below is a prefix, so every
        # decision derived from it is unreliable.
        if ($list.Count -gt [int]$cap) { $out.complete = $false }
        $count = 0
        foreach ($f in $list) {
            if ($count -ge [int]$cap) { break }
            $count++
            $id = [IO.Path]::GetFileNameWithoutExtension($f)
            # Fail-closed on an unreadable store: a file in the candidates
            # directory that cannot be interpreted as the candidate it claims
            # to be leaves this store unprovable as "free of another promoted
            # change", so the enumeration is INCOMPLETE and promotion refuses
            # (EVOLUTION_ENUMERATION_INCOMPLETE). Three ways that happens:
            #   (a) the FILE NAME is not a candidate id;
            #   (b) the file is larger than the hard record cap - checked via
            #       FileInfo BEFORE any ReadAllText, so an oversized/corrupt
            #       file is never loaded into memory (SEC-4);
            #   (c) the file is unreadable, not JSON, not an object, carries an
            #       unknown status, or its embedded candidate_id does not match
            #       the file name (identity: a record cannot claim to be a
            #       different candidate than the file it lives in).
            if (-not (Test-EvolutionCandidateId -Value $id)) { $out.complete = $false; continue }
            $length = [long]-1
            try { $length = ([IO.FileInfo]::new($f)).Length } catch { $out.complete = $false; continue }
            if ($length -gt [long]$script:EvolutionHardCapRecordBytes) { $out.complete = $false; continue }
            $doc = $null
            try { $doc = ConvertTo-EvolutionOrdered -Node (([IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false))) | ConvertFrom-Json) } catch { $out.complete = $false; continue }
            if (-not ($doc -is [System.Collections.IDictionary])) { $out.complete = $false; continue }
            $status = [string](Get-EvolutionValue $doc 'status' 'unknown')
            if ($status -cnotin @('candidate', 'promoted', 'rolled_back')) { $out.complete = $false; continue }
            $recordId = [string](Get-EvolutionValue $doc 'candidate_id' '')
            if ((-not (Test-EvolutionCandidateId -Value $recordId)) -or ($recordId -cne $id)) { $out.complete = $false; continue }
            [void]$entries.Add([PSCustomObject]@{
                    candidate_id = $recordId
                    status       = $status
                    created_at   = [string](Get-EvolutionValue $doc 'created_at' '')
                })
        }
        $out.entries = @($entries.ToArray())
        return ([PSCustomObject]$out)
    }
    catch { $out.ok = $false; return ([PSCustomObject]$out) }
}

function Get-OrchestrationEvolutionCandidateList {
    <#
    .SYNOPSIS
        Lists stored candidate summaries (id + status only, bounded by the
        policy candidate-file cap, ordinal name order). Read-only.
        Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StoreDir, $Policy)
    try {
        $inv = Get-EvolutionCandidateInventory -StoreDir $StoreDir -Policy $Policy
        if (-not [bool]$inv.ok) { return @() }
        return @($inv.entries)
    }
    catch { return @() }
}

# ---------- R3: candidate creation ----------

function New-OrchestrationEvolutionCandidate {
    <#
    .SYNOPSIS
        Creates an EVOLUTION_CANDIDATE record from repeated evidence.
        Accepted only when sample_count >= min_sample_threshold AND
        distinct evidence refs >= min_distinct_refs; otherwise nothing is
        written and a structured rejected-threshold result is returned with
        the observed counts (one anecdote never yields a promotable rule).
        Nothing here touches production policy. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Problem,
        [Parameter(Mandatory = $true)]$RepeatedEvidenceRefs,
        [Parameter(Mandatory = $true)][string]$GeneralizedCause,
        [Parameter(Mandatory = $true)][string]$ProposedChange,
        [Parameter(Mandatory = $true)][string]$ExpectedEffect,
        [Parameter(Mandatory = $true)][string]$Risk,
        [Parameter(Mandatory = $true)][string]$RollbackPlan,
        [string]$StoreDir,
        [string]$PolicyPath,
        [string]$RepoRoot,
        $AtUtc
    )
    try {
        $resolved = Resolve-EvolutionPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$resolved.ok) { return $resolved }
        $policy = $resolved.policy
        $store = $StoreDir
        if ([string]::IsNullOrWhiteSpace($store)) { $store = Get-EvolutionDefaultStoreDir -RepoRoot $RepoRoot }
        if ([string]::IsNullOrWhiteSpace($store)) { return (New-EvolutionError -Code 'EVOLUTION_STORE_REQUIRED') }
        $maxText = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_text_length' -Fallback 500)
        $maxRef = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_ref_length' -Fallback 128)
        $maxRefs = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_evidence_refs' -Fallback 20)
        $thr = [int](Get-EvolutionValue $policy 'min_sample_threshold' 0)
        $minDistinct = [int](Get-EvolutionValue $policy 'min_distinct_refs' 1)
        $problemText = Get-EvolutionSafeText -Value $Problem -MaxLength $maxText
        $causeText = Get-EvolutionSafeText -Value $GeneralizedCause -MaxLength $maxText
        $changeText = Get-EvolutionSafeText -Value $ProposedChange -MaxLength $maxText
        $effectText = Get-EvolutionSafeText -Value $ExpectedEffect -MaxLength $maxText
        $riskText = Get-EvolutionSafeText -Value $Risk -MaxLength $maxText
        $rollbackText = Get-EvolutionSafeText -Value $RollbackPlan -MaxLength $maxText
        foreach ($pair in @(@('problem', $problemText), @('generalized_cause', $causeText), @('proposed_change', $changeText), @('expected_effect', $effectText), @('risk', $riskText), @('rollback_plan', $rollbackText))) {
            if ([string]::IsNullOrWhiteSpace([string]$pair[1])) { return (New-EvolutionError -Code ('EVOLUTION_INVALID_' + ([string]$pair[0]).ToUpperInvariant())) }
        }
        $refs = @()
        $rejectedRefs = 0
        foreach ($r in @($RepeatedEvidenceRefs)) {
            if ($refs.Count -ge $maxRefs) { break }
            $safe = Get-EvolutionSafeText -Value ([string]$r) -MaxLength $maxRef
            $safe = $safe.Trim()
            if (-not (Test-EvolutionSafeRef -Value $safe)) { $rejectedRefs++; continue }
            $refs += $safe
        }
        $sampleCount = $refs.Count
        $distinct = @($refs | Sort-Object -Unique)
        $distinctCount = $distinct.Count
        if (($sampleCount -lt $thr) -or ($distinctCount -lt $minDistinct)) {
            return [PSCustomObject]@{
                ok                   = $false
                error                = ''
                status               = 'rejected-threshold'
                candidate_id         = ''
                sample_count         = [int]$sampleCount
                distinct_refs        = [int]$distinctCount
                min_sample_threshold = [int]$thr
                min_distinct_refs    = [int]$minDistinct
                refs_rejected        = [int]$rejectedRefs
                prom                 = $false
                production_mutation  = 'none'
                written              = $false
            }
        }
        $material = (ConvertTo-Json -InputObject ([ordered]@{
                    problem            = $problemText
                    generalized_cause  = $causeText
                    proposed_change    = $changeText
                    expected_effect    = $effectText
                    risk               = $riskText
                    rollback_plan      = $rollbackText
                    repeated_evidence  = $refs
                }) -Depth 6 -Compress)
        $candidateId = ('evc-' + (Get-EvolutionHashHex -Text $material -Length 16))
        $now = Get-EvolutionUtcNowText -AtUtc $AtUtc
        $record = [ordered]@{
            schema_version        = 1
            record_type           = 'EVOLUTION_CANDIDATE'
            candidate_id          = $candidateId
            status                = 'candidate'
            problem               = $problemText
            generalized_cause     = $causeText
            proposed_change       = $changeText
            expected_effect       = $effectText
            risk                  = $riskText
            rollback_plan         = $rollbackText
            repeated_evidence     = $refs
            sample_count          = [int]$sampleCount
            distinct_refs         = [int]$distinctCount
            min_sample_threshold  = [int]$thr
            min_distinct_refs     = [int]$minDistinct
            policy_version        = [int](Get-EvolutionValue $policy 'version' 1)
            automatic_promotion   = $false
            production_mutation   = 'none'
            created_at            = $now
            redacted              = $true
        }
        $lock = Enter-EvolutionStoreLock -StoreDir $store -LockTimeoutMs (Get-EvolutionPolicyCap -Policy $policy -Name 'lock_timeout_ms' -Fallback 200)
        if (-not [bool]$lock.ok) { return (New-EvolutionError -Code ([string]$lock.error)) }
        try {
            # Composite-failure guard: a store locked by a previous failed
            # restore refuses every further mutation until intervention.
            if (Test-EvolutionStoreLocked -StoreDir $store) { return (New-EvolutionError -Code 'EVOLUTION_STORE_LOCKED') }
            $targetPath = Get-EvolutionCandidatePath -StoreDir $store -CandidateId $candidateId
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                # Bounded store: creation REJECTS at the candidate-file cap
                # instead of growing without limit (a promoted candidate could
                # otherwise be pushed outside the one-at-a-time window).
                $inventory = Get-EvolutionCandidateInventory -StoreDir $store -Policy $policy
                if ([int]$inventory.total_files -ge [int]$inventory.cap) {
                    return (New-EvolutionError -Code 'EVOLUTION_STORE_CANDIDATE_LIMIT' -Extra @{ cap = [int]$inventory.cap; candidate_id = $candidateId })
                }
            }
            $save = Save-EvolutionCandidateRecord -StoreDir $store -Policy $policy -Record $record
            if (-not [bool]$save.ok) {
                # Keep the size detail of a refused stored record (SEC-4)
                # without ever returning a candidate_id: a refused creation
                # must not hand back something that looks promotable.
                $saveExtra = @{}
                if ($null -ne $save.bytes) { $saveExtra['bytes'] = [long]$save.bytes }
                if ($null -ne $save.cap) { $saveExtra['cap'] = [int]$save.cap }
                return (New-EvolutionError -Code ([string]$save.error) -Extra $saveExtra)
            }
            $idempotent = ([string]$save.error -ceq 'idempotent')
            $historyEvent = [ordered]@{
                schema_version      = 1
                record_type         = 'EVOLUTION_EVENT'
                event               = 'created'
                candidate_id        = $candidateId
                status_before       = ''
                status_after        = 'candidate'
                reason              = (Get-EvolutionSafeText -Value ([string]$Problem) -MaxLength 240)
                sample_count        = [int]$sampleCount
                at                  = $now
                production_mutation = 'none'
            }
            # Identical re-creation is a no-op: it must not duplicate history.
            if (-not $idempotent) {
                $hist = Add-EvolutionHistoryEvent -StoreDir $store -Policy $policy -Event $historyEvent
                if (-not [bool]$hist.ok) {
                    # V3: a record that cannot be audited (no 'created' event)
                    # must never exist, so the creation is rolled back here.
                    # A failed rollback is a COMPOSITE failure: the store is
                    # locked instead of being left silently inconsistent.
                    $rollback = Remove-EvolutionCandidateRecord -StoreDir $store -CandidateId $candidateId
                    if (-not [bool]$rollback.ok) {
                        [void](Set-EvolutionStoreLocked -StoreDir $store -Reason ('history-and-rollback-failed:' + [string]$hist.error))
                        return (New-EvolutionError -Code 'EVOLUTION_STORE_LOCKED' -Extra @{ history_error = [string]$hist.error; candidate_id = $candidateId })
                    }
                    return (New-EvolutionError -Code ([string]$hist.error) -Extra @{ rolled_back = $true; candidate_id = $candidateId })
                }
            }
        }
        finally { Exit-EvolutionStoreLock -Lock $lock.handle }
        return [PSCustomObject]@{
            ok                   = $true
            error                = ''
            status               = 'candidate'
            candidate_id         = $candidateId
            sample_count         = [int]$sampleCount
            distinct_refs        = [int]$distinctCount
            min_sample_threshold = [int]$thr
            min_distinct_refs    = [int]$minDistinct
            refs_rejected        = [int]$rejectedRefs
            prom                 = $false
            production_mutation  = 'none'
            written              = $true
            record               = [PSCustomObject]$record
        }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_FAILED') }
}

# ---------- R4: offline eval ----------

function Get-EvolutionFixtureMetric {
    <#
    .SYNOPSIS
        Reads one fixture metric as a rate/level double, or $null when the
        key is absent/unparsable/out of range. Closed field set (target ids
        from the policy), culture-independent parse. Never throws.
    #>
    [CmdletBinding()]
    param($Fixture, [Parameter(Mandatory = $true)][string]$Target, [int]$MaxValue = 1000000)
    try {
        $raw = Get-EvolutionValue $Fixture $Target $null
        if ($null -eq $raw) { return $null }
        if ($raw -is [bool]) { return $null }
        if (-not ($raw -is [int] -or $raw -is [long] -or $raw -is [double] -or $raw -is [single] -or $raw -is [decimal] -or $raw -is [string])) { return $null }
        $dbl = 0.0
        if ($raw -is [string]) {
            if (-not [double]::TryParse([string]$raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dbl)) { return $null }
        }
        else { $dbl = [double]$raw }
        if ([double]::IsNaN($dbl) -or [double]::IsInfinity($dbl)) { return $null }
        if (($dbl -lt 0.0) -or ($dbl -gt [double]$MaxValue)) { return $null }
        return $dbl
    }
    catch { return $null }
}

function ConvertTo-EvolutionFixture {
    <#
    .SYNOPSIS
        Accepts a fixture as a file path (JSON) or as an in-memory object
        and returns @{ok; samples; metrics}. Malformed/unreadable input
        returns @{ok=$false} with an error code. Never throws.
    #>
    [CmdletBinding()]
    param($Fixture, $Policy)
    try {
        $doc = $null
        if ($null -eq $Fixture) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_MISSING' } }
        if (($Fixture -is [string]) -or ($Fixture -is [System.IO.FileInfo])) {
            $path = [string]$Fixture
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_UNREADABLE' } }
            $text = $null
            try { $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) } catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_UNREADABLE' } }
            if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 262144) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_TOO_LARGE' } }
            try { $doc = ($text | ConvertFrom-Json) } catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_MALFORMED' } }
        }
        else { $doc = $Fixture }
        $rec = ConvertTo-EvolutionOrdered -Node $doc
        if (-not ($rec -is [System.Collections.IDictionary])) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_MALFORMED' } }
        $samples = Get-EvolutionValue $rec 'samples' $null
        if (-not (Test-EvolutionStrictInt -Value $samples -Min 0 -Max 1000000)) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_SAMPLES_INVALID' } }
        $metrics = Get-EvolutionValue $rec 'metrics' $null
        if ($null -eq $metrics) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_METRICS_MISSING' } }
        $mrec = ConvertTo-EvolutionOrdered -Node $metrics
        if (-not ($mrec -is [System.Collections.IDictionary])) { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_METRICS_MISSING' } }
        $label = Get-EvolutionSafeText -Value ([string](Get-EvolutionValue $rec 'label' '')) -MaxLength 64
        return [PSCustomObject]@{ ok = $true; error = ''; samples = [int]$samples; metrics = $mrec; label = $label }
    }
    catch { return [PSCustomObject]@{ ok = $false; error = 'EVOLUTION_FIXTURE_MALFORMED' } }
}

function Compare-EvolutionVariant {
    <#
    .SYNOPSIS
        Pure per-target comparison between a baseline and a variant
        (candidate or shadow). Returns @{verdict; deltas; compared;
        improved; unchanged; regressed; missing}. Classification honours the
        declared direction and the absolute tolerance; a target missing on
        either side is 'missing' (incomparable, never assumed zero).
        Never throws.
    #>
    [CmdletBinding()]
    param($Baseline, $Variant, $Policy)
    $rows = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $tolerance = [double](Get-EvolutionValue $Policy 'shadow_comparison_tolerance' 0.0)
    $maxValue = (Get-EvolutionPolicyCap -Policy $Policy -Name 'max_metric_value' -Fallback 1000000)
    $compared = 0
    $improved = 0
    $unchanged = 0
    $regressed = 0
    try {
        foreach ($t in @(Get-EvolutionTargetSpec -Policy $Policy)) {
            $id = [string]$t.id
            $base = Get-EvolutionFixtureMetric -Fixture $Baseline.metrics -Target $id -MaxValue $maxValue
            $var = Get-EvolutionFixtureMetric -Fixture $Variant.metrics -Target $id -MaxValue $maxValue
            if (($null -eq $base) -or ($null -eq $var)) {
                [void]$missing.Add($id)
                [void]$rows.Add([PSCustomObject]@{
                        target      = $id
                        direction   = [string]$t.direction
                        baseline    = $base
                        candidate   = $var
                        delta       = $null
                        delta_text  = ''
                        tolerance   = [double]$tolerance
                        comparison  = 'missing'
                    })
                continue
            }
            $delta = [Math]::Round(([double]$var - [double]$base), 6)
            $class = 'unchanged'
            if ([Math]::Abs($delta) -gt $tolerance) {
                if ([string]$t.direction -ceq 'higher_is_better') {
                    if ($delta -gt 0) { $class = 'improved' } else { $class = 'regression' }
                }
                else {
                    if ($delta -lt 0) { $class = 'improved' } else { $class = 'regression' }
                }
            }
            if ($class -eq 'improved') { $improved++ } elseif ($class -eq 'regression') { $regressed++ } else { $unchanged++ }
            $compared++
            [void]$rows.Add([PSCustomObject]@{
                    target      = $id
                    direction   = [string]$t.direction
                    baseline    = [double]$base
                    candidate   = [double]$var
                    delta       = [double]$delta
                    delta_text  = (Get-EvolutionInvariantText -Value $delta -Digits 6)
                    tolerance   = [double]$tolerance
                    comparison  = $class
                })
        }
    }
    catch { }
    return [PSCustomObject]@{
        deltas    = @($rows.ToArray())
        missing   = @($missing.ToArray())
        compared  = [int]$compared
        improved  = [int]$improved
        unchanged = [int]$unchanged
        regressed = [int]$regressed
        tolerance = [double]$tolerance
    }
}

function Invoke-OrchestrationEvolutionEval {
    <#
    .SYNOPSIS
        Offline/replay evaluation: compares a candidate fixture against a
        baseline fixture (and, when supplied, a shadow/A-B variant) using the
        policy tolerance, declared directions, the per-variant sample floor
        and require_no_regression. Verdict is 'pass', 'regression' or
        'inconclusive'; 'pass' additionally requires FULL target coverage
        (every declared target comparable), otherwise the verdict is
        'inconclusive' with reasons. Read-only: no store, no policy and no
        production write happens here. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$BaselineFixture,
        [Parameter(Mandatory = $true)]$CandidateFixture,
        $ShadowFixture,
        [string]$PolicyPath,
        [string]$RepoRoot,
        $AtUtc
    )
    try {
        $resolved = Resolve-EvolutionPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$resolved.ok) { return $resolved }
        $policy = $resolved.policy
        $baseline = ConvertTo-EvolutionFixture -Fixture $BaselineFixture -Policy $policy
        if (-not [bool]$baseline.ok) { return (New-EvolutionError -Code ([string]$baseline.error) -Extra @{ baseline = $true }) }
        $candidate = ConvertTo-EvolutionFixture -Fixture $CandidateFixture -Policy $policy
        if (-not [bool]$candidate.ok) { return (New-EvolutionError -Code ([string]$candidate.error) -Extra @{ candidate = $true }) }
        $shadow = $null
        if ($null -ne $ShadowFixture) {
            $shadow = ConvertTo-EvolutionFixture -Fixture $ShadowFixture -Policy $policy
            if (-not [bool]$shadow.ok) { return (New-EvolutionError -Code ([string]$shadow.error) -Extra @{ shadow = $true }) }
        }
        $evalNode = Get-EvolutionValue $policy 'eval' $null
        $floor = [int](Get-EvolutionValue $evalNode 'min_samples_per_variant' 1)
        $requireNoRegression = [bool](Get-EvolutionValue $evalNode 'require_no_regression' $true)
        $candCmp = Compare-EvolutionVariant -Baseline $baseline -Variant $candidate -Policy $policy
        $shadowCmp = $null
        if ($null -ne $shadow) { $shadowCmp = Compare-EvolutionVariant -Baseline $baseline -Variant $shadow -Policy $policy }
        $declaredTargets = @(Get-EvolutionTargetSpec -Policy $policy).Count
        $verdict = 'pass'
        $reasons = New-Object System.Collections.ArrayList
        if (($baseline.samples -lt $floor) -or ($candidate.samples -lt $floor)) {
            $verdict = 'inconclusive'
            [void]$reasons.Add('samples-below-floor')
        }
        if ($candCmp.compared -eq 0) {
            $verdict = 'inconclusive'
            [void]$reasons.Add('no-comparable-target')
        }
        # V4: 'pass' requires EVERY declared target to be comparable. A
        # partial comparison can hide a regression in the unmeasured
        # targets, so incomplete coverage downgrades a pass to
        # 'inconclusive' with the missing ids listed.
        if ($candCmp.compared -lt $declaredTargets) {
            if ($verdict -ceq 'pass') { $verdict = 'inconclusive' }
            [void]$reasons.Add('incomplete-target-coverage')
        }
        # A confirmed regression is reported even when the run is otherwise
        # inconclusive: inconclusive must never mask a measured regression.
        if ($requireNoRegression -and ($candCmp.regressed -gt 0)) {
            $verdict = 'regression'
            [void]$reasons.Add('candidate-regression')
        }
        if ($null -ne $shadowCmp) {
            if ($shadow.samples -lt $floor) { if ($verdict -ceq 'pass') { $verdict = 'inconclusive' }; [void]$reasons.Add('shadow-samples-below-floor') }
            if ($shadowCmp.compared -eq 0) { if ($verdict -ceq 'pass') { $verdict = 'inconclusive' }; [void]$reasons.Add('shadow-no-comparable-target') }
            if ($shadowCmp.compared -lt $declaredTargets) { if ($verdict -ceq 'pass') { $verdict = 'inconclusive' }; [void]$reasons.Add('shadow-incomplete-target-coverage') }
            if (($shadowCmp.compared -gt 0) -and ($requireNoRegression) -and ($shadowCmp.regressed -gt 0)) { $verdict = 'regression'; [void]$reasons.Add('shadow-regression') }
        }
        return [PSCustomObject]@{
            ok               = $true
            error            = ''
            verdict          = $verdict
            reasons          = @($reasons.ToArray())
            baseline_samples = [int]$baseline.samples
            candidate_samples = [int]$candidate.samples
            shadow_samples   = $(if ($null -eq $shadow) { -1 } else { [int]$shadow.samples })
            tolerance        = [double](Get-EvolutionValue $policy 'shadow_comparison_tolerance' 0.0)
            deltas           = @($candCmp.deltas)
            compared         = [int]$candCmp.compared
            improved         = [int]$candCmp.improved
            unchanged        = [int]$candCmp.unchanged
            regressed        = [int]$candCmp.regressed
            missing_targets  = @($candCmp.missing)
            shadow           = $shadowCmp
            evaluated_at     = (Get-EvolutionUtcNowText -AtUtc $AtUtc)
            production_mutation = 'none'
        }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_EVAL_FAILED') }
}

# ---------- R5/R6: explicit promotion + rollback ----------

function Set-EvolutionCandidateStatus {
    <#
    .SYNOPSIS
        Shared promotion/rollback transition. Caller holds the store lock and
        has already validated the transition against the record it re-read
        inside that lock. Writes the updated record first and appends the
        history event second; if the history append fails (cap/IO) the
        previous record is restored AND the restoration is verified by
        re-reading it (V5: no silent restore). A restoration that cannot be
        verified is a COMPOSITE failure: the store is locked with
        EVOLUTION_STORE_LOCKED, blocking further transitions until an
        operator intervenes. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StoreDir,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$NewStatus,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$Now
    )
    try {
        $id = [string](Get-EvolutionValue $Record 'candidate_id' '')
        $path = Get-EvolutionCandidatePath -StoreDir $StoreDir -CandidateId $id
        $beforeText = $null
        try { if (Test-Path -LiteralPath $path -PathType Leaf) { $beforeText = [IO.File]::ReadAllText($path) } } catch { return (New-EvolutionError -Code 'EVOLUTION_RECORD_UNREADABLE') }
        $updated = ConvertTo-EvolutionOrdered -Node $Record
        $updated['status'] = [string]$NewStatus
        $updated['updated_at'] = [string]$Now
        if ([string]$NewStatus -ceq 'promoted') { $updated['promoted_at'] = [string]$Now }
        if ([string]$NewStatus -ceq 'rolled_back') { $updated['rolled_back_at'] = [string]$Now; $updated['rollback_reason'] = [string]$Reason }
        $save = Save-EvolutionCandidateRecord -StoreDir $StoreDir -Policy $Policy -Record $updated -Overwrite
        if (-not [bool]$save.ok) { return (New-EvolutionError -Code ([string]$save.error)) }
        $historyEvent = [ordered]@{
            schema_version      = 1
            record_type         = 'EVOLUTION_EVENT'
            event               = [string]$Event
            candidate_id        = [string]$id
            status_before       = [string](Get-EvolutionValue $Record 'status' '')
            status_after        = [string]$NewStatus
            reason              = [string]$Reason
            at                  = [string]$Now
            production_mutation = 'none'
        }
        $hist = Add-EvolutionHistoryEvent -StoreDir $StoreDir -Policy $Policy -Event $historyEvent
        if (-not [bool]$hist.ok) {
            $restored = $false
            try {
                if ($null -ne $beforeText) { [IO.File]::WriteAllText($path, $beforeText, [Text.UTF8Encoding]::new($false)) }
                else { if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) } }
                $restored = $true
            }
            catch { $restored = $false }
            # Verifiable restoration: re-read the file instead of trusting
            # the write call. A silent half-restore is a COMPOSITE failure.
            if ($restored) {
                if ($null -ne $beforeText) {
                    $verify = $null
                    try { $verify = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) } catch { $verify = $null }
                    if ($verify -cne $beforeText) { $restored = $false }
                }
                else {
                    if (Test-Path -LiteralPath $path -PathType Leaf) { $restored = $false }
                }
            }
            if (-not $restored) {
                [void](Set-EvolutionStoreLocked -StoreDir $StoreDir -Reason ('transition-history-and-restore-failed:' + [string]$hist.error))
                return (New-EvolutionError -Code 'EVOLUTION_STORE_LOCKED' -Extra @{ history_error = [string]$hist.error; status = 'locked' })
            }
            return (New-EvolutionError -Code ([string]$hist.error) -Extra @{ restored = 'verified' })
        }
        return [PSCustomObject]@{ ok = $true; error = ''; record = [PSCustomObject]$updated }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_TRANSITION_FAILED') }
}

function Approve-OrchestrationEvolutionCandidate {
    <#
    .SYNOPSIS
        EXPLICIT promotion decision (never automatic). Requires the stored
        candidate in status 'candidate' (re-read and re-validated inside the
        store lock), the eval verdict required by policy
        (promotion_requires.shadow_comparison) and, when the policy demands
        it, a non-empty review marker. One change at a time: a candidate
        already promoted and not rolled back blocks a second promotion, and
        an incomplete store enumeration (more candidate files than the cap)
        blocks it outright. Writes only the candidate record + history inside
        the store; it never writes production policy (addendum
        18.6/18.7). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CandidateId,
        [string]$ReviewMarker = '',
        [Parameter(Mandatory = $true)][string]$EvalVerdict,
        [string]$StoreDir,
        [string]$PolicyPath,
        [string]$RepoRoot,
        $AtUtc
    )
    try {
        $resolved = Resolve-EvolutionPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$resolved.ok) { return $resolved }
        $policy = $resolved.policy
        $store = $StoreDir
        if ([string]::IsNullOrWhiteSpace($store)) { $store = Get-EvolutionDefaultStoreDir -RepoRoot $RepoRoot }
        if ([string]::IsNullOrWhiteSpace($store)) { return (New-EvolutionError -Code 'EVOLUTION_STORE_REQUIRED') }
        if (-not (Test-EvolutionCandidateId -Value $CandidateId)) { return (New-EvolutionError -Code 'EVOLUTION_INVALID_CANDIDATE_ID') }
        $requires = Get-EvolutionValue $policy 'promotion_requires' $null
        $requiredVerdict = ([string](Get-EvolutionValue $requires 'shadow_comparison' 'pass')).Trim()
        $requiresMarker = [bool](Get-EvolutionValue $requires 'review_marker' $true)
        $maxMarker = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_review_marker_length' -Fallback 120)
        $marker = Get-EvolutionSafeText -Value $ReviewMarker -MaxLength $maxMarker
        $verdict = ([string]$EvalVerdict).Trim().ToLowerInvariant()
        if ($verdict -cnotin @('pass', 'regression', 'inconclusive')) { return (New-EvolutionError -Code 'EVOLUTION_EVAL_VERDICT_INVALID') }
        $failure = $null
        if ($requiresMarker -and [string]::IsNullOrWhiteSpace($marker)) { $failure = 'EVOLUTION_REVIEW_MARKER_REQUIRED' }
        elseif ($verdict -cne $requiredVerdict) { $failure = ('EVOLUTION_EVAL_' + $verdict.ToUpperInvariant() + '_BLOCKS_PROMOTION') }
        if ($null -ne $failure) {
            return [PSCustomObject]@{
                ok                  = $false
                error               = $failure
                status              = 'rejected'
                candidate_id        = [string]$CandidateId
                eval_verdict        = $verdict
                required_verdict    = $requiredVerdict
                review_marker       = ''
                review_marker_required = [bool]$requiresMarker
                production_mutation = 'none'
                written             = $false
            }
        }
        $found = Get-OrchestrationEvolutionCandidate -StoreDir $store -CandidateId ([string]$CandidateId)
        if (-not [bool]$found.ok) { return (New-EvolutionError -Code ([string]$found.error)) }
        $now = Get-EvolutionUtcNowText -AtUtc $AtUtc
        $lock = Enter-EvolutionStoreLock -StoreDir $store -LockTimeoutMs (Get-EvolutionPolicyCap -Policy $policy -Name 'lock_timeout_ms' -Fallback 200)
        if (-not [bool]$lock.ok) { return (New-EvolutionError -Code ([string]$lock.error)) }
        try {
            if (Test-EvolutionStoreLocked -StoreDir $store) { return (New-EvolutionError -Code 'EVOLUTION_STORE_LOCKED') }
            # V5: the decision is re-read and re-validated INSIDE the lock.
            # A read taken before the lock is a TOCTOU window where a
            # concurrent decision would be silently overwritten.
            $locked = Get-OrchestrationEvolutionCandidate -StoreDir $store -CandidateId ([string]$CandidateId)
            if (-not [bool]$locked.ok) { return (New-EvolutionError -Code ([string]$locked.error)) }
            $record = $locked.record
            $status = [string](Get-EvolutionValue $record 'status' '')
            if ($status -ceq 'promoted') { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_ALREADY_PROMOTED') }
            if ($status -ceq 'rolled_back') { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_ALREADY_ROLLED_BACK') }
            # V5/V7: one-at-a-time is decided from the WHOLE store. A store
            # with more candidate files than the cap means this window is
            # only a prefix and a promoted change could hide outside it, so
            # the promotion fails closed instead of guessing.
            $inventory = Get-EvolutionCandidateInventory -StoreDir $store -Policy $policy
            if (-not [bool]$inventory.ok) { return (New-EvolutionError -Code 'EVOLUTION_STORE_UNREADABLE') }
            if (-not [bool]$inventory.complete) {
                return (New-EvolutionError -Code 'EVOLUTION_ENUMERATION_INCOMPLETE' -Extra @{ files = [int]$inventory.total_files; cap = [int]$inventory.cap })
            }
            foreach ($other in @($inventory.entries)) {
                if (([string]$other.candidate_id -cne ([string]$CandidateId)) -and ([string]$other.status -ceq 'promoted')) {
                    return (New-EvolutionError -Code 'EVOLUTION_ONE_CHANGE_AT_A_TIME')
                }
            }
            $reason = ('review marker: ' + $marker + '; eval verdict: ' + $verdict)
            $transition = Set-EvolutionCandidateStatus -StoreDir $store -Policy $policy -Record $record -NewStatus 'promoted' -Event 'promoted' -Reason $reason -Now $now
            if (-not [bool]$transition.ok) { return $transition }
        }
        finally { Exit-EvolutionStoreLock -Lock $lock.handle }
        return [PSCustomObject]@{
            ok                  = $true
            error               = ''
            status              = 'promoted'
            candidate_id        = [string]$CandidateId
            eval_verdict        = $verdict
            required_verdict    = $requiredVerdict
            review_marker       = $marker
            review_marker_required = [bool]$requiresMarker
            production_mutation = 'none'
            applied             = $false
            apply_path          = 'reviewed-code-change'
            written             = $true
            record              = $transition.record
        }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_PROMOTION_FAILED') }
}

function Rollback-OrchestrationEvolutionCandidate {
    <#
    .SYNOPSIS
        EXPLICIT rollback decision with a mandatory reason. Restores the
        pre-promotion state marker ('candidate'), records the reason in the
        bounded history and unblocks the next one-at-a-time promotion. Like
        promotion it is a decision record only: the effective reversion of a
        behavior stays the normal reviewed-code flow. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CandidateId,
        [string]$Reason = '',
        [string]$StoreDir,
        [string]$PolicyPath,
        [string]$RepoRoot,
        $AtUtc
    )
    try {
        $resolved = Resolve-EvolutionPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$resolved.ok) { return $resolved }
        $policy = $resolved.policy
        $store = $StoreDir
        if ([string]::IsNullOrWhiteSpace($store)) { $store = Get-EvolutionDefaultStoreDir -RepoRoot $RepoRoot }
        if ([string]::IsNullOrWhiteSpace($store)) { return (New-EvolutionError -Code 'EVOLUTION_STORE_REQUIRED') }
        if (-not (Test-EvolutionCandidateId -Value $CandidateId)) { return (New-EvolutionError -Code 'EVOLUTION_INVALID_CANDIDATE_ID') }
        $maxReason = (Get-EvolutionPolicyCap -Policy $policy -Name 'max_reason_length' -Fallback 240)
        $safeReason = Get-EvolutionSafeText -Value $Reason -MaxLength $maxReason
        if ([string]::IsNullOrWhiteSpace($safeReason)) {
            return [PSCustomObject]@{
                ok                  = $false
                error               = 'EVOLUTION_REASON_REQUIRED'
                status              = 'rejected'
                candidate_id        = [string]$CandidateId
                production_mutation = 'none'
                written             = $false
            }
        }
        $found = Get-OrchestrationEvolutionCandidate -StoreDir $store -CandidateId ([string]$CandidateId)
        if (-not [bool]$found.ok) { return (New-EvolutionError -Code ([string]$found.error)) }
        $now = Get-EvolutionUtcNowText -AtUtc $AtUtc
        $lock = Enter-EvolutionStoreLock -StoreDir $store -LockTimeoutMs (Get-EvolutionPolicyCap -Policy $policy -Name 'lock_timeout_ms' -Fallback 200)
        if (-not [bool]$lock.ok) { return (New-EvolutionError -Code ([string]$lock.error)) }
        try {
            if (Test-EvolutionStoreLocked -StoreDir $store) { return (New-EvolutionError -Code 'EVOLUTION_STORE_LOCKED') }
            # V5: same rule as promotion - the decision is made from the
            # record read inside the lock, never from a pre-lock read.
            $locked = Get-OrchestrationEvolutionCandidate -StoreDir $store -CandidateId ([string]$CandidateId)
            if (-not [bool]$locked.ok) { return (New-EvolutionError -Code ([string]$locked.error)) }
            $record = $locked.record
            $status = [string](Get-EvolutionValue $record 'status' '')
            if ($status -cne 'promoted') { return (New-EvolutionError -Code 'EVOLUTION_CANDIDATE_NOT_PROMOTED') }
            $transition = Set-EvolutionCandidateStatus -StoreDir $store -Policy $policy -Record $record -NewStatus 'rolled_back' -Event 'rolled_back' -Reason $safeReason -Now $now
            if (-not [bool]$transition.ok) { return $transition }
        }
        finally { Exit-EvolutionStoreLock -Lock $lock.handle }
        return [PSCustomObject]@{
            ok                  = $true
            error               = ''
            status              = 'rolled_back'
            candidate_id        = [string]$CandidateId
            previous_status     = 'promoted'
            restored_candidate_state = 'candidate'
            reason              = $safeReason
            rollback_plan       = [string](Get-EvolutionValue $record 'rollback_plan' '')
            production_mutation = 'none'
            applied             = $false
            apply_path          = 'reviewed-code-change'
            written             = $true
            record              = $transition.record
        }
    }
    catch { return (New-EvolutionError -Code 'EVOLUTION_ROLLBACK_FAILED') }
}
