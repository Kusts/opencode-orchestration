<#!
.SYNOPSIS
    V3 observational telemetry producer for the evolution loop (Phase 41
    slice 2, RR-P41-S2-TELEMETRY-PRODUCERS).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Phase 41 slice 1
    (OrchestrationEvolutionLoop.ps1) DEFINES the telemetry contract but
    nothing in the kernel produced its counters yet; this file closes that
    gap with an OBSERVATIONAL producer and nothing else:

      - Invoke-OrchestrationTelemetryProduction reads the real artifacts the
        kernel already writes and derives the counters declared by
        source/registry/evolution-policy.json eval_targets. Every derived
        number is a measurement of a real file, never a guess.
      - A counter with NO real source is ABSENT from the record and listed in
        unavailable_counters with a short sanitized reason. Nothing is
        fabricated and nothing is zero-filled to look complete.
      - Record-only by default: without an explicit -OutDir this function
        performs ZERO writes. With -OutDir it appends exactly one bounded
        JSONL line (evolution-telemetry-YYYYMMDD.jsonl, LF-terminated).
      - The produced line is consumed by the slice-1 reader
        (Get-EvolutionTelemetryFiles / ConvertTo-EvolutionCounters /
        Get-OrchestrationEvolutionSignals) without rejection.

    COUNTER SHAPE (slice-1 contract, not a choice made here):
        ConvertTo-EvolutionCounters reads the TOP-LEVEL properties of a
        telemetry record only. Counters are therefore emitted as flat
        top-level integer fields, in declared policy-target order, and the
        metadata keys below (record_type, generated_at, producer,
        policy_version, redacted, unavailable_counters, sources, clock_note)
        are never declared counter names. A collision between a metadata key
        and a declared counter name is refused closed
        (EVOLUTION_TELEMETRY_METADATA_COLLISION) instead of shadowing a
        counter.

    DECLARED COUNTER MAPPING (all field names are REAL kernel/watchdog/evidence
    field names; nothing here reads a field that does not exist, and a counter
    whose field is absent from real records stays unavailable):

      From TasksDir (kernel task records, schema v1):
        tasks                     = valid records examined (schema_version is
                                    a strict int AND task_id is a non-empty
                                    string).
        wall_time_s               = sum, over those records, of the observed
                                    task lifetime floor(updated_at -
                                    created_at) in whole seconds. Records
                                    whose pair is missing, unparsable or
                                    inverted contribute 0 and increment
                                    timestamps_invalid. (A single record-level
                                    window is the only real duration the
                                    record carries; per-attempt durations are
                                    NOT derivable - attempts[] only stores the
                                    instant of a FAILED attempt.)
        reviewer_rounds           = records carrying a `review` object (the
                                    kernel keeps ONE reviewer verdict slot per
                                    task, so this counts reviewer verdicts,
                                    not review invocations).
        reviewer_findings         = records whose review.status is
                                    'changes_required' (case-sensitive).
        tester_rounds             = records whose observed attempt-role binding
                                    is the tester role
                                    (execution_runtime.attempt_role,
                                    closed match, case-sensitive). The kernel
                                    persists the role of the CURRENT attempt
                                    only, so this is a lower bound.
        tester_duplication_events = for records with a tester binding: observed
                                    strategy fingerprints minus DISTINCT
                                    strategy fingerprints, where the observed
                                    set is attempts[].strategy_fingerprint
                                    plus execution_runtime.gate_evidence.
                                    strategy_fingerprint. ONE observation per
                                    REAL attempt: the kernel copies the current
                                    fingerprint into attempts[] when it
                                    records a failure and does NOT touch
                                    execution_runtime, so a gate still
                                    describes the attempt named by
                                    execution_runtime.attempt_n. The gate
                                    counts only when that attempt_n matches no
                                    recorded attempt number (Ordinal
                                    comparison, never an array index) - that is
                                    the real ACTIVE attempt. A gate whose
                                    execution_runtime.attempt_n matches a
                                    recorded attempt (or carries no matchable
                                    attempt_n) is a copy of an attempt already
                                    in attempts[] and is not summed
                                    (gate-already-recorded).
        tool_loop_tasks           = records where the same difference is > 0
                                    (repeated strategy fingerprint).
        budget_exceeded_tasks     = records whose state, or any history[].to,
                                    matches ^(EXHAUSTED|BUDGET_[A-Z0-9_]*)$.

      From WatchdogDir (watchdog-*.jsonl, P25 shadow telemetry). The
      recognized vocabulary is exactly what the watchdog really emits
      (OrchestrationRuntimeWatchdog.ps1 allowedClass, L549): HARD_TIMEOUT,
      NO_PROGRESS, REPEATED_ACTION, REPEATED_CYCLE, BUDGET_NEAR_LIMIT. A bare
      'CYCLE' is not emitted by the watchdog and is NOT recognized; an
      unrecognized class becomes 'other' and is counted.
        tool_loop_tasks           = DISTINCT task_hash16 whose class is
                                    REPEATED_ACTION or REPEATED_CYCLE.
        budget_exceeded_tasks     = NOT derived here. BUDGET_NEAR_LIMIT is a
                                    PREVENTIVE threshold (emitted with
                                    would_interrupt=$false), so it does not
                                    prove an overrun; it is counted under
                                    sources.watchdog.events_by_class only.
                                    budget_exceeded_tasks comes from the task
                                    records (EXHAUSTED / BUDGET_*).
        HARD_TIMEOUT and NO_PROGRESS feed no policy counter (a timeout is not
        a budget overrun and wall time is already owned by the task records);
        they are counted under sources.watchdog.events_by_class only.
        Watchdog events carry task_hash16 while task records carry task_id, so
        the two observation windows are NEVER summed - each counter has ONE
        owner source, first configured owner in the declared order wins, and
        the production result reports the owner per counter. A watchdog
        directory whose files are ALL unreadable reports the source
        unavailable (never zeros), so it cannot suppress the task fallback.

      From EvidenceMetricsPath (OrchestrationEvidenceStore reuse-metrics.jsonl):
        evidence_available       = count of lines whose `metric` is
                                    records_created.
        evidence_reused          = count of lines whose `metric` is reuse_hits,
                                    available only when the file really carries
                                    a reuse signal (reuse_hits/reuse_misses);
                                    otherwise unavailable, never invented.

      With NO real source at all (structurally unproducible today):
        jev_calls, jev_useful_calls, user_interventions are ALWAYS absent with
        a declared reason. There is no JEV call ledger and no human
        intervention signal in the kernel records; writing 0 would be a lie.

    DOWNSTREAM NOTE (slice-1 aggregation, deliberately not worked around):
        the slice-1 aggregator sums the numerator over the records that carry
        the DENOMINATOR, so a target whose numerator is legitimately absent
        still aggregates as 0 when its denominator is present. user_
        intervention_rate therefore reads 0 downstream even though this
        producer never emits user_interventions. That is the unchanged
        slice-1 contract (an absent numerator is not a refusal), and the
        honest statement stays in the record: the numerator is ABSENT and
        listed in unavailable_counters. jev_useful_call_rate has no real
        denominator source either, so it stays no-data.

    BOUNDS (all from the policy caps; policy may only tighten the local
    ceilings below):
      - task files: MaxTaskFiles (default 200, hard ceiling 5000), ordinal
        file order, files_total reported so a cap is never silent;
      - JSONL lines per file: max_telemetry_records; the per-line byte cap is
        EFFECTIVE: no line is ever materialized beyond
        max_telemetry_line_bytes, an over-cap line is drained to its
        terminator without accumulating (a 1 MB line costs a fixed 4 KB
        buffer) and counted, and an unterminated final line within the cap is
        processed normally;
      - JSONL line size: max_telemetry_line_bytes; output line size: the same
        cap, and an over-cap line is refused WHOLE (nothing is truncated and
        nothing is written);
      - task-record FILE size: max_telemetry_file_bytes. A kernel task record
        is a record, not a telemetry line - applying the 4096-byte line cap to
        it would skip every real record. Size and read happen on ONE handle,
        so a record that grows after the check cannot bypass the cap; the same
        single-handle rule applies to the JSONL per-file cap;
      - counter values: 0..max_metric_value, strict integers only;
      - output file size: max_telemetry_file_bytes, measured AND appended
        through the SAME exclusive FileShare.None handle, so a cross-process
        writer cannot slip past the accounting; a contended handle is a silent
        skip (fail-closed, never a crash).

    SANITIZATION: every string that can reach the record is a constant, a
    policy-declared counter name (closed charset), a closed-vocabulary reason
    or an already-sanitized helper output. Host-derived text (objectives,
    actors, failure details, fingerprints, file names, host names) is NEVER
    copied into the record.

    PowerShell 5.1 compatible. ASCII-only. No process, no network. Expected
    domain errors are returned as result objects ({ok=$false; error='CODE'}),
    never thrown. Helpers of the slice-1 loop (Get-EvolutionValue,
    Get-EvolutionSafeText, Test-EvolutionStrictInt, Get-EvolutionTargetSpec,
    Get-EvolutionPolicyCap, Test-EvolutionPolicyShape, Resolve-EvolutionPolicy,
    ConvertTo-EvolutionOrdered) are reused by lazy dot-source - no logic is
    duplicated here.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Local safety ceilings. The policy caps may only tighten these.
$script:EvolutionTelemetryHardMaxTaskFiles = 5000
$script:EvolutionTelemetryHardMaxReasonLength = 80
$script:EvolutionTelemetryHardMaxTaskRecordBytes = 33554432
$script:EvolutionTelemetryProducerTag = 'observation-only'

# Closed vocabularies. Host data is matched against these, never joined into
# a reason or an emitted key.
$script:EvolutionTelemetryTesterRoles = @('tester')
# Watchdog classes as the watchdog REALLY emits them
# (OrchestrationRuntimeWatchdog.ps1 allowedClass, L549): HARD_TIMEOUT,
# NO_PROGRESS, REPEATED_ACTION, REPEATED_CYCLE, BUDGET_NEAR_LIMIT. A bare
# 'CYCLE' is NOT emitted by the watchdog - recognizing it would map nothing
# real and would let a real REPEATED_CYCLE fall into 'other'.
$script:EvolutionTelemetryLoopClasses = @('REPEATED_ACTION', 'REPEATED_CYCLE')
$script:EvolutionTelemetryKnownClasses = @('HARD_TIMEOUT', 'NO_PROGRESS', 'REPEATED_ACTION', 'REPEATED_CYCLE', 'BUDGET_NEAR_LIMIT')
$script:EvolutionTelemetryBudgetExhaustedPattern = '^(EXHAUSTED|BUDGET_[A-Z0-9_]{1,31})$'
$script:EvolutionTelemetryFingerprintMaxLength = 128

# Declared reasons for counters that have no real source today. Constants, so
# the reason is identical on every engine and every run.
$script:EvolutionTelemetryNoSourceReasons = @{
    'jev_calls'           = 'no-real-source:jev-call-events-not-recorded'
    'jev_useful_calls'    = 'no-real-source:jev-outcome-signal-not-recorded'
    'user_interventions'  = 'no-real-source:human-intervention-signal-not-recorded'
}

# Declared counter ownership: for each policy counter name, the ordered list of
# sources allowed to own its value (first configured owner wins). Counters
# with no entry here fall back to $script:EvolutionTelemetryNoSourceReasons.
$script:EvolutionTelemetryCounterOwners = [ordered]@{
    'tasks'                     = @('tasks')
    'wall_time_s'               = @('tasks')
    'reviewer_rounds'           = @('tasks')
    'reviewer_findings'         = @('tasks')
    'tester_rounds'             = @('tasks')
    'tester_duplication_events' = @('tasks')
    'tool_loop_tasks'           = @('watchdog', 'tasks')
    # BUDGET_NEAR_LIMIT is a PREVENTIVE threshold (the watchdog emits it with
    # would_interrupt=$false), so it does not prove an overrun and the
    # watchdog is NOT an owner here. Only a real EXHAUSTED/BUDGET_* task
    # record is.
    'budget_exceeded_tasks'     = @('tasks')
    'evidence_available'        = @('evidence')
    'evidence_reused'           = @('evidence')
}

$script:EvolutionTelemetryMetadataKeys = @(
    'record_type', 'generated_at', 'producer', 'policy_version', 'redacted',
    'unavailable_counters', 'sources', 'clock_note'
)

# ---------- dependency (lazy dot-source of the slice-1 loop) ----------

function Test-EvolutionTelemetryLoopLoaded {
    <#
    .SYNOPSIS
        True when the slice-1 loop helpers are already in scope. The lazy
        dot-source itself happens in the CALLING scope (a dot-source inside a
        helper would define the helpers in that helper's scope, where they
        would not be visible to the producer). Never throws.
    #>
    [CmdletBinding()]
    param()
    try { return ($null -ne (Get-Command -Name 'Get-EvolutionTargetSpec' -CommandType Function -ErrorAction SilentlyContinue)) }
    catch { return $false }
}

function New-EvolutionTelemetryError {
    <#
    .SYNOPSIS
        Structured domain error. Never throws.
    #>
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

# ---------- bounded, sanitized primitives ----------

function Get-EvolutionTelemetrySafeReason {
    <#
    .SYNOPSIS
        Closed-charset, length-capped reason token for counters and source
        accounting. Applied to every reason token that leaves this library so
        no host text can ride along. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s)) { return 'unspecified' }
        $s = ($s -replace '[^A-Za-z0-9:._-]', '-')
        if ($s.Length -gt $script:EvolutionTelemetryHardMaxReasonLength) {
            $s = $s.Substring(0, $script:EvolutionTelemetryHardMaxReasonLength)
        }
        if ([string]::IsNullOrWhiteSpace($s)) { return 'unspecified' }
        return $s
    }
    catch { return 'unspecified' }
}

function Add-EvolutionTelemetrySkip {
    <#
    .SYNOPSIS
        Increments a closed-vocabulary skip counter in an ordered map. Keys
        are sanitized, so an unexpected reason can never grow the map without
        bound. Never throws.
    #>
    [CmdletBinding()]
    param($Map, [Parameter(Mandatory = $true)][string]$Reason, [int]$Count = 1)
    try {
        $k = (Get-EvolutionTelemetrySafeReason -Value $Reason)
        $c = [int]$Count
        if ($c -lt 1) { $c = 1 }
        if (-not $Map.Contains($k)) { $Map[$k] = 0 }
        $Map[$k] = ([int]$Map[$k] + $c)
    }
    catch { }
}

function ConvertTo-EvolutionTelemetryInstant {
    <#
    .SYNOPSIS
        Engine-independent instant seam. PS 7 materializes date-like JSON
        strings as [DateTime] while PS 5.1 keeps [string], so both are
        accepted; returns a UTC [DateTime] or $null. Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return $null }
        if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
        if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dto)) {
            return $dto.UtcDateTime
        }
        return $null
    }
    catch { return $null }
}

function Get-EvolutionTelemetryDeclaredCounters {
    <#
    .SYNOPSIS
        Counter names declared by the policy eval_targets, in declared order,
        de-duplicated, closed charset only. Never throws.
    #>
    [CmdletBinding()]
    param($Policy)
    $out = New-Object System.Collections.ArrayList
    try {
        $seen = @{}
        foreach ($t in @(Get-EvolutionTargetSpec -Policy $Policy)) {
            foreach ($raw in @([string]$t.numerator, [string]$t.denominator)) {
                $n = $raw.Trim()
                if ($n -notmatch '^[a-z][a-z0-9_]{1,63}$') { continue }
                if ($seen.ContainsKey($n)) { continue }
                $seen[$n] = $true
                [void]$out.Add($n)
            }
        }
        return @($out.ToArray())
    }
    catch { return @() }
}

function Get-EvolutionTelemetrySourceFiles {
    <#
    .SYNOPSIS
        Bounded, ordinal-sorted file list for one source. Returns
        @{ok; files[]; total; truncated}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$Pattern, [int]$MaxFiles = 64)
    $out = [ordered]@{ ok = $false; files = @(); total = 0; truncated = $false; reason = 'source-absent' }
    try {
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return [PSCustomObject]$out }
        $all = [string[]]@([IO.Directory]::GetFiles($Dir, $Pattern, [IO.SearchOption]::TopDirectoryOnly))
        $list = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $all) { [void]$list.Add([string]$f) }
        $list.Sort([StringComparer]::Ordinal)
        $out.total = [int]$list.Count
        $n = [int]$MaxFiles
        if ($n -lt 1) { $n = 1 }
        $keep = @()
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($keep.Count -ge $n) { $out.truncated = $true; break }
            $keep += $list[$i]
        }
        $out.ok = $true
        $out.reason = ''
        $out.files = $keep
        return [PSCustomObject]$out
    }
    catch { $out.reason = 'source-unreadable'; return [PSCustomObject]$out }
}

function Read-EvolutionTelemetryJsonLines {
    <#
    .SYNOPSIS
        Bounded incremental JSONL read over ONE handle. The per-file byte cap
        is measured on the same handle that is read, and the read stops at
        that MEASURED LENGTH: the handle permits concurrent writes, so the
        length is captured once and the total bytes read are limited to the
        bytes remaining in that snapshot. A file that grows (or is appended
        to) while it is read can never push the reader past the measured
        bound; whatever the snapshot cuts is handled by the ordinary
        final-line rules. The line cap is EFFECTIVE on BOTH accumulation
        paths - with and without the terminator inside the buffer: a fixed
        4 KB buffer plus at most MaxLineBytes accumulated bytes, so a hostile
        1 MB (or 1 GB) line is drained to its terminator without ever being
        materialized. An unterminated final line within the cap is processed;
        over the cap it is counted and dropped. MaxLines is checked BEFORE a
        line is converted or included (same order as the unterminated EOF
        branch), so the reader never returns one line beyond the cap; the
        excess line is still counted (max-lines-reached). Every line counted
        against MaxLines, blank included. Returns @{ok; lines[]; examined;
        skipped; skipped_by_reason; truncated; reason}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxLines = 2000, [int]$MaxLineBytes = 4096, [int]$MaxFileBytes = 4194304)
    $lines = New-Object System.Collections.ArrayList
    $byReason = [ordered]@{}
    $out = [ordered]@{ ok = $true; lines = @(); examined = 0; skipped = 0; skipped_by_reason = $byReason; truncated = $false; reason = '' }
    try {
        $cap = [long]$MaxLineBytes
        if ($cap -lt 1) { $cap = 1 }
        $fileCap = [long]$MaxFileBytes
        if ($fileCap -lt 1) { $fileCap = 1 }
        $maxLines = [int]$MaxLines
        if ($maxLines -lt 1) { $maxLines = 1 }
        $stream = $null
        try { $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) }
        catch { $out.ok = $false; $out.reason = 'file-unreadable'; return [PSCustomObject]$out }
        try {
            # The length measured on THIS handle is the snapshot the read is
            # confined to. The share mode permits a concurrent writer, so the
            # cap is only meaningful if the read cannot outrun the measurement.
            $snapshot = [long]$stream.Length
            if ($snapshot -gt $fileCap) { $out.ok = $false; $out.reason = 'file-too-large'; return [PSCustomObject]$out }
            $remaining = $snapshot
            $buf = New-Object byte[] 4096
            $pos = 0
            $len = 0
            $acc = New-Object System.Collections.ArrayList
            $over = $false
            $stop = $false
            while (-not $stop) {
                $idx = -1
                for ($i = $pos; $i -lt $len; $i++) { if ($buf[$i] -eq 10) { $idx = $i; break } }
                if ($idx -ge 0) {
                    # Complete line: the terminator is inside the buffer. The
                    # segment still has to fit the cap, exactly like the
                    # unterminated segment below - otherwise an over-cap line
                    # is materialized whenever its terminator lands inside the
                    # buffer instead of being drained.
                    if (-not $over) {
                        $seg = ($idx - $pos)
                        if (($acc.Count + $seg) -gt $cap) { $over = $true; $acc.Clear() }
                        elseif ($seg -gt 0) { [void]$acc.AddRange([byte[]]$buf[$pos..($idx - 1)]) }
                    }
                    $pos = ($idx + 1)
                    $wasOver = $over
                    $text = ''
                    if (-not $wasOver) { $text = [Text.Encoding]::UTF8.GetString([byte[]]$acc.ToArray()) }
                    $acc.Clear()
                    $over = $false
                    # The MaxLines bound is checked BEFORE the line is converted
                    # or included - the same order as the unterminated EOF
                    # branch - so a bounded reader never returns one line more
                    # than the cap. The excess line is still counted, so the
                    # truncation is never silent.
                    if ([int]$out.examined -ge $maxLines) {
                        $out.examined = ([int]$out.examined + 1)
                        Add-EvolutionTelemetrySkip -Map $byReason -Reason 'max-lines-reached'
                        $out.truncated = $true
                        $stop = $true
                        continue
                    }
                    $out.examined = ([int]$out.examined + 1)
                    if ($wasOver) { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'line-too-long' }
                    elseif ([string]::IsNullOrWhiteSpace($text)) { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'blank-line' }
                    else {
                        $row = $null
                        try { $row = ($text | ConvertFrom-Json) }
                        catch { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'unparsable-line' }
                        if ($null -ne $row) {
                            $ord = ConvertTo-EvolutionOrdered -Node $row
                            if ($ord -is [System.Collections.IDictionary]) { [void]$lines.Add($ord) }
                            else { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'not-an-object' }
                        }
                        elseif ($null -eq $row) { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'unparsable-line' }
                    }
                    continue
                }
                # No terminator in the buffer: keep only what fits the cap.
                if (-not $over) {
                    $seg = ($len - $pos)
                    if (($acc.Count + $seg) -gt $cap) { $over = $true; $acc.Clear() }
                    elseif ($seg -gt 0) { [void]$acc.AddRange([byte[]]$buf[$pos..($len - 1)]) }
                }
                $pos = $len
                # Never read past the snapshot measured above: a concurrent
                # append cannot extend what this reader consumes.
                $n = 0
                if ($remaining -gt 0) {
                    $want = [int][Math]::Min([long]$buf.Length, [long]$remaining)
                    try { $n = $stream.Read($buf, 0, $want) }
                    catch { $out.ok = $false; $out.reason = 'file-unreadable'; return [PSCustomObject]$out }
                    $remaining = ([long]$remaining - [long]$n)
                }
                if ($n -gt 0) { $len = $n; $pos = 0; continue }
                # EOF of the snapshot: an over-cap or unterminated final line
                # is still counted.
                if ($over) {
                    $out.examined = ([int]$out.examined + 1)
                    Add-EvolutionTelemetrySkip -Map $byReason -Reason 'line-too-long'
                    if ([int]$out.examined -gt $maxLines) { $out.truncated = $true }
                }
                elseif ($acc.Count -gt 0) {
                    $text = [Text.Encoding]::UTF8.GetString([byte[]]$acc.ToArray())
                    $out.examined = ([int]$out.examined + 1)
                    if ([int]$out.examined -gt $maxLines) { $out.truncated = $true }
                    else {
                        $row = $null
                        try { $row = ($text | ConvertFrom-Json) }
                        catch { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'unparsable-line' }
                        if ($null -ne $row) {
                            $ord = ConvertTo-EvolutionOrdered -Node $row
                            if ($ord -is [System.Collections.IDictionary]) { [void]$lines.Add($ord) }
                            else { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'not-an-object' }
                        }
                        elseif ($null -eq $row) { Add-EvolutionTelemetrySkip -Map $byReason -Reason 'unparsable-line' }
                    }
                }
                $stop = $true
            }
        }
        finally { try { if ($null -ne $stream) { $stream.Dispose() } } catch { } }
        $out.lines = @($lines.ToArray())
        $sum = 0
        foreach ($v in @($byReason.Values)) { $sum += [int]$v }
        $out.skipped = [int]$sum
        return [PSCustomObject]$out
    }
    catch { $out.ok = $false; $out.reason = 'file-unreadable'; return [PSCustomObject]$out }
}

function Read-EvolutionTelemetryTaskRecord {
    <#
    .SYNOPSIS
        Reads one bounded task record (a whole-file JSON record, not a
        telemetry line) through a SINGLE handle: the size cap is measured on
        the same handle that is read and the read stops at that measured
        length, so a record that grows after the check cannot bypass the cap
        (no second open, no TOCTOU). Returns @{ok; record; reason}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 4194304)
    $out = [ordered]@{ ok = $false; record = $null; reason = 'file-unreadable' }
    try {
        $cap = [long]$MaxBytes
        if ($cap -lt 1) { $cap = 1 }
        $stream = $null
        try { $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) }
        catch { $out.reason = 'file-unreadable'; return [PSCustomObject]$out }
        try {
            $len = [long]$stream.Length
            if ($len -gt $cap) { $out.reason = 'record-too-large'; return [PSCustomObject]$out }
            if ($len -le 0) { $out.reason = 'unparsable-record'; return [PSCustomObject]$out }
            $buf = New-Object byte[] ([int]$len)
            $read = 0
            while ($read -lt $len) {
                $n = 0
                try { $n = $stream.Read($buf, $read, [int]($len - $read)) }
                catch { $out.reason = 'file-unreadable'; return [PSCustomObject]$out }
                if ($n -le 0) { break }
                $read = ($read + $n)
                if ([long]$read -gt $cap) { $out.reason = 'record-too-large'; return [PSCustomObject]$out }
            }
            $text = [Text.Encoding]::UTF8.GetString($buf, 0, [int]$read)
            if ([string]::IsNullOrWhiteSpace($text)) { $out.reason = 'unparsable-record'; return [PSCustomObject]$out }
            $doc = $null
            try { $doc = ($text | ConvertFrom-Json) } catch { $out.reason = 'unparsable-record'; return [PSCustomObject]$out }
            if ($null -eq $doc) { $out.reason = 'unparsable-record'; return [PSCustomObject]$out }
            $rec = ConvertTo-EvolutionOrdered -Node $doc
            if (-not ($rec -is [System.Collections.IDictionary])) { $out.reason = 'not-an-object'; return [PSCustomObject]$out }
            $out.ok = $true
            $out.reason = ''
            $out.record = $rec
            return [PSCustomObject]$out
        }
        finally { try { if ($null -ne $stream) { $stream.Dispose() } } catch { } }
    }
    catch { $out.ok = $false; $out.reason = 'file-unreadable'; return [PSCustomObject]$out }
}

function Test-EvolutionTelemetryRecordIdentity {
    <#
    .SYNOPSIS
        A task record counts as a task only when the kernel identity fields
        are really there: schema_version as a strict int and a non-empty
        task_id. Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        if (-not ($Record -is [System.Collections.IDictionary])) { return $false }
        if (-not (Test-EvolutionStrictInt -Value (Get-EvolutionValue $Record 'schema_version' $null) -Min 1 -Max 1000)) { return $false }
        $tid = Get-EvolutionValue $Record 'task_id' ''
        if ($null -eq $tid) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$tid)) { return $false }
        return $true
    }
    catch { return $false }
}

function ConvertTo-EvolutionTelemetryFingerprintText {
    <#
    .SYNOPSIS
        Bounded, sanitized fingerprint text used only for identity comparison.
        Returns '' when the value is blank or over the fingerprint bound (the
        caller counts the rejection). Never throws.
    #>
    [CmdletBinding()]
    param($Value, $Skips)
    try {
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s.Length -gt $script:EvolutionTelemetryFingerprintMaxLength) {
            Add-EvolutionTelemetrySkip -Map $Skips -Reason 'fingerprint-oversize'
            return ''
        }
        $clean = Get-EvolutionSafeText -Value $s -MaxLength $script:EvolutionTelemetryFingerprintMaxLength
        if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
        return [string]$clean
    }
    catch { return '' }
}

function Get-EvolutionTelemetryFingerprints {
    <#
    .SYNOPSIS
        Observed strategy fingerprints of one task record - ONE observation per
        REAL attempt, never one per stored copy of it. Values are sanitized and
        capped before any comparison, so a hostile fingerprint can neither leak
        nor blow up memory. Never throws.

        The kernel copies the current fingerprint into attempts[] when it
        records a failed attempt (OrchestrationTaskKernel.ps1 L1642-1661) and
        persists execution_runtime afterwards (L1680-1682) WITHOUT touching
        execution_runtime.attempt_n, so two real shapes exist:

          - post-failure copy: attempts[n] holds the fingerprint the gate also
            holds and execution_runtime.attempt_n is still that n. The gate is
            the SAME attempt already in attempts[] and must NOT be summed;
          - real ACTIVE attempt: attempts[n] holds only the earlier failures
            and execution_runtime.attempt_n is n+1 (the next attempt, started
            through the attempt entry point, L3836-3846). That gate IS an
            observation of a real attempt and must be counted.

        The gate object itself carries NO attempt number
        (OrchestrationTaskKernel.ps1 L3671-3677): the attempt it belongs to is
        execution_runtime.attempt_n. Reading a field the kernel never writes
        would discard every REAL active gate as gate-already-recorded and hide
        genuine duplication. Attempt identity is therefore the ORDINAL
        comparison of execution_runtime.attempt_n against the recorded
        attempts[].n numbers, never an array index. A gate with no matchable
        execution_runtime.attempt_n is treated as a copy and is NOT summed.
    #>
    [CmdletBinding()]
    param($Record, $Skips)
    $out = New-Object System.Collections.ArrayList
    try {
        $recordedNs = New-Object 'System.Collections.Generic.List[string]'
        $recordedRaw = New-Object System.Collections.ArrayList
        $attempts = Get-EvolutionValue $Record 'attempts' $null
        if ($null -ne $attempts) {
            foreach ($a in @($attempts)) {
                if (-not ($a -is [System.Collections.IDictionary])) { continue }
                $n = Get-EvolutionValue $a 'n' $null
                if (Test-EvolutionStrictInt -Value $n -Min 1 -Max 1000000) { [void]$recordedNs.Add([string][int]$n) }
                $fp = Get-EvolutionValue $a 'strategy_fingerprint' ''
                if ($null -ne $fp) { [void]$recordedRaw.Add([string]$fp) }
            }
        }
        foreach ($v in @($recordedRaw.ToArray())) {
            $clean = ConvertTo-EvolutionTelemetryFingerprintText -Value $v -Skips $Skips
            if (-not [string]::IsNullOrWhiteSpace($clean)) { [void]$out.Add($clean) }
        }
        $rt = Get-EvolutionValue $Record 'execution_runtime' $null
        $ge = $null
        if (($rt -is [System.Collections.IDictionary]) -and $rt.Contains('gate_evidence')) { $ge = $rt['gate_evidence'] }
        if ($ge -is [System.Collections.IDictionary]) {
            $gfp = Get-EvolutionValue $ge 'strategy_fingerprint' ''
            if ($null -ne $gfp) {
                $gtext = ([string]$gfp).Trim()
                if (-not [string]::IsNullOrWhiteSpace($gtext)) {
                    # The attempt this gate describes is
                    # execution_runtime.attempt_n: the kernel writes
                    # attempt_n on execution_runtime (L3843) and the gate
                    # object itself has no attempt number at all (L3671-3677).
                    # Reading the gate for it would always find nothing and
                    # discard every real ACTIVE gate.
                    $gn = $null
                    if ($rt -is [System.Collections.IDictionary]) { $gn = Get-EvolutionValue $rt 'attempt_n' $null }
                    # The gate counts ONLY when it names an attempt that
                    # identifies no recorded attempt (the real active attempt,
                    # not yet recorded). A match - or no matchable
                    # execution_runtime.attempt_n at all - means the gate is a
                    # copy of an attempt already in attempts[] and is NOT
                    # summed.
                    $countsAsAttempt = $false
                    if (Test-EvolutionStrictInt -Value $gn -Min 1 -Max 1000000) {
                        $gnText = [string][int]$gn
                        $matched = $false
                        foreach ($rn in @($recordedNs.ToArray())) {
                            if ([string]$rn -ceq $gnText) { $matched = $true; break }
                        }
                        if (-not $matched) { $countsAsAttempt = $true }
                    }
                    if (-not $countsAsAttempt) { Add-EvolutionTelemetrySkip -Map $Skips -Reason 'gate-already-recorded' }
                    else {
                        $gclean = ConvertTo-EvolutionTelemetryFingerprintText -Value $gtext -Skips $Skips
                        if (-not [string]::IsNullOrWhiteSpace($gclean)) { [void]$out.Add($gclean) }
                    }
                }
            }
        }
        return @($out.ToArray())
    }
    catch { return @() }
}

function Test-EvolutionTelemetryBudgetExhaustedRecord {
    <#
    .SYNOPSIS
        True when the task state, or any history transition target, is an
        exhaustion/budget terminal marker (closed pattern, case-sensitive).
        Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        $state = ([string](Get-EvolutionValue $Record 'state' '')).Trim().ToUpperInvariant()
        if ($state -cmatch $script:EvolutionTelemetryBudgetExhaustedPattern) { return $true }
        $hist = Get-EvolutionValue $Record 'history' $null
        if ($null -ne $hist) {
            foreach ($h in @($hist)) {
                if (-not ($h -is [System.Collections.IDictionary])) { continue }
                $to = ([string](Get-EvolutionValue $h 'to' '')).Trim().ToUpperInvariant()
                if ($to -cmatch $script:EvolutionTelemetryBudgetExhaustedPattern) { return $true }
            }
        }
        return $false
    }
    catch { return $false }
}

function Get-EvolutionTelemetryAttemptRole {
    <#
    .SYNOPSIS
        Observed attempt-role binding of a task record (the kernel persists
        the role of the CURRENT attempt only). Returns '' when absent. Never
        throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        $rt = Get-EvolutionValue $Record 'execution_runtime' $null
        if (-not ($rt -is [System.Collections.IDictionary])) { return '' }
        return ([string](Get-EvolutionValue $rt 'attempt_role' '')).Trim()
    }
    catch { return '' }
}

# ---------- source measures ----------

function Measure-EvolutionTelemetryTasks {
    <#
    .SYNOPSIS
        Derives the task-owned counters from real kernel task records. Returns
        @{ok; counters; source}. The counters present in the result are the
        ones this source produced; absent ones are not fabricated. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$TasksDir = '',
        [int]$MaxTaskFiles = 200,
        [int]$MaxRecordBytes = 4194304
    )
    $byReason = [ordered]@{}
    $counters = [ordered]@{}
    $src = [ordered]@{
        state              = 'not-configured'
        files_total        = 0
        files_examined     = 0
        files_skipped      = 0
        records_examined   = 0
        records_valid      = 0
        records_skipped    = 0
        truncated          = $false
        timestamps_invalid = 0
        skipped_by_reason  = $byReason
        counters_derived     = [object[]]@()
    }
    $out = [ordered]@{ ok = $false; counters = $counters; source = $src }
    try {
        if ([string]::IsNullOrWhiteSpace($TasksDir)) { return [PSCustomObject]$out }
        $n = [int]$MaxTaskFiles
        if ($n -lt 1) { $n = 1 }
        if ($n -gt $script:EvolutionTelemetryHardMaxTaskFiles) { $n = $script:EvolutionTelemetryHardMaxTaskFiles }
        $listing = Get-EvolutionTelemetrySourceFiles -Dir $TasksDir -Pattern '*.json' -MaxFiles $n
        $src.files_total = [int]$listing.total
        $src.truncated = [bool]$listing.truncated
        if (-not [bool]$listing.ok) { $src.state = 'absent'; return [PSCustomObject]$out }
        $src.state = 'examined'
        $src.files_examined = @($listing.files).Count
        $tasks = 0
        $budgetExhausted = 0
        $reviewRounds = 0
        $reviewFindings = 0
        $testerRounds = 0
        $testerDup = 0
        $loopTasks = 0
        [long]$wall = 0
        foreach ($file in @($listing.files)) {
            $slot = Read-EvolutionTelemetryTaskRecord -Path ([string]$file) -MaxBytes $MaxRecordBytes
            if (-not [bool]$slot.ok) {
                $src.files_skipped = ([int]$src.files_skipped + 1)
                Add-EvolutionTelemetrySkip -Map $byReason -Reason ([string]$slot.reason)
                continue
            }
            $src.records_examined = ([int]$src.records_examined + 1)
            $rec = $slot.record
            if (-not (Test-EvolutionTelemetryRecordIdentity -Record $rec)) {
                Add-EvolutionTelemetrySkip -Map $byReason -Reason 'missing-identity'
                continue
            }
            $src.records_valid = ([int]$src.records_valid + 1)
            $tasks++
            # budget exhaustion (state or history transition)
            if (Test-EvolutionTelemetryBudgetExhaustedRecord -Record $rec) { $budgetExhausted++ }
            # reviewer rounds/findings (single verdict slot per task)
            $review = Get-EvolutionValue $rec 'review' $null
            if ($review -is [System.Collections.IDictionary]) {
                $reviewRounds++
                $rs = ([string](Get-EvolutionValue $review 'status' '')).Trim()
                if ($rs -ceq 'changes_required') { $reviewFindings++ }
            }
            # observed attempt role + strategy fingerprint repetition
            $role = Get-EvolutionTelemetryAttemptRole -Record $rec
            $isTester = $false
            foreach ($tr in @($script:EvolutionTelemetryTesterRoles)) { if ($role -ceq $tr) { $isTester = $true } }
            if ($isTester) { $testerRounds++ }
            $fps = @(Get-EvolutionTelemetryFingerprints -Record $rec -Skips $byReason)
            $dup = 0
            if ($fps.Count -gt 0) {
                $distinct = New-Object 'System.Collections.Generic.List[string]'
                foreach ($f in $fps) { if (-not $distinct.Contains([string]$f)) { [void]$distinct.Add([string]$f) } }
                $dup = ($fps.Count - $distinct.Count)
                if ($dup -gt 0) { $loopTasks++ }
            }
            if ($isTester) { $testerDup += $dup }
            # observed task lifetime
            $created = ConvertTo-EvolutionTelemetryInstant (Get-EvolutionValue $rec 'created_at' $null)
            $updated = ConvertTo-EvolutionTelemetryInstant (Get-EvolutionValue $rec 'updated_at' $null)
            if (($null -eq $created) -or ($null -eq $updated)) {
                $src.timestamps_invalid = ([int]$src.timestamps_invalid + 1)
            }
            else {
                $delta = ($updated - $created).TotalSeconds
                if ($delta -lt 0.0) { $src.timestamps_invalid = ([int]$src.timestamps_invalid + 1) }
                else { $wall += [long][Math]::Floor($delta) }
            }
        }
        $src.records_skipped = ([int]$src.records_examined - [int]$src.records_valid)
        $counters['tasks'] = [int]$tasks
        $counters['wall_time_s'] = [long]$wall
        $counters['reviewer_rounds'] = [int]$reviewRounds
        $counters['reviewer_findings'] = [int]$reviewFindings
        $counters['tester_rounds'] = [int]$testerRounds
        $counters['tester_duplication_events'] = [int]$testerDup
        $counters['tool_loop_tasks'] = [int]$loopTasks
        $counters['budget_exceeded_tasks'] = [int]$budgetExhausted
        $owned = @()
        foreach ($k in @($counters.Keys)) { $owned += [string]$k }
        $src.counters_derived = [object[]]@($owned)
        $out.ok = $true
        return [PSCustomObject]$out
    }
    catch { $src.state = 'unreadable'; return [PSCustomObject]$out }
}

function Measure-EvolutionTelemetryWatchdog {
    <#
    .SYNOPSIS
        Derives the watchdog-owned counters from real watchdog-*.jsonl lines
        (DISTINCT task_hash16 per class family). HARD_TIMEOUT / NO_PROGRESS map
        to no policy counter and are only accounted. Never throws.

        Only tool_loop_tasks is derived here: BUDGET_NEAR_LIMIT is a preventive
        threshold, not a proven overrun, so it stays in events_by_class only.
        When files were found but NONE could be read, the source stays
        unavailable with a reason: publishing zeros here would win the owner
        order and silently suppress the task-record fallback.
    #>
    [CmdletBinding()]
    param(
        [string]$WatchdogDir = '',
        [int]$MaxFiles = 64,
        [int]$MaxLines = 2000,
        [int]$MaxLineBytes = 4096,
        [int]$MaxFileBytes = 4194304
    )
    $byReason = [ordered]@{}
    $classes = [ordered]@{}
    foreach ($c in @($script:EvolutionTelemetryKnownClasses)) { $classes[[string]$c] = 0 }
    $classes['other'] = 0
    $counters = [ordered]@{}
    $src = [ordered]@{
        state            = 'not-configured'
        files_examined   = 0
        files_read       = 0
        files_skipped    = 0
        lines_examined   = 0
        lines_skipped    = 0
        events_by_class  = $classes
        truncated        = $false
        skipped_by_reason = $byReason
        counters_derived   = [object[]]@()
    }
    $out = [ordered]@{ ok = $false; counters = $counters; source = $src }
    try {
        if ([string]::IsNullOrWhiteSpace($WatchdogDir)) { return [PSCustomObject]$out }
        $listing = Get-EvolutionTelemetrySourceFiles -Dir $WatchdogDir -Pattern 'watchdog-*.jsonl' -MaxFiles $MaxFiles
        if (-not [bool]$listing.ok) { $src.state = 'absent'; return [PSCustomObject]$out }
        $src.state = 'examined'
        $src.files_examined = @($listing.files).Count
        $loopTasks = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($file in @($listing.files)) {
            $slot = Read-EvolutionTelemetryJsonLines -Path ([string]$file) -MaxLines $MaxLines -MaxLineBytes $MaxLineBytes -MaxFileBytes $MaxFileBytes
            if (-not [bool]$slot.ok) {
                $src.files_skipped = ([int]$src.files_skipped + 1)
                Add-EvolutionTelemetrySkip -Map $byReason -Reason ([string]$slot.reason)
                continue
            }
            $src.files_read = ([int]$src.files_read + 1)
            $src.lines_examined = ([int]$src.lines_examined + [int]$slot.examined)
            $src.lines_skipped = ([int]$src.lines_skipped + [int]$slot.skipped)
            if ([bool]$slot.truncated) { $src.truncated = $true }
            foreach ($k in @($slot.skipped_by_reason.Keys)) { Add-EvolutionTelemetrySkip -Map $byReason -Reason ([string]$k) -Count ([int]$slot.skipped_by_reason[$k]) }
            foreach ($row in @($slot.lines)) {
                $cls = ([string](Get-EvolutionValue $row 'class' '')).Trim().ToUpperInvariant()
                if (-not $classes.Contains($cls)) { $cls = 'other' }
                $classes[[string]$cls] = ([int]$classes[[string]$cls] + 1)
                $hash = ([string](Get-EvolutionValue $row 'task_hash16' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($hash)) { continue }
                if ($script:EvolutionTelemetryLoopClasses -ccontains $cls) { [void]$loopTasks.Add($hash) }
            }
        }
        if (([int]$src.files_examined -gt 0) -and ([int]$src.files_read -eq 0)) {
            # Every discovered watchdog file failed to read: zeros here would
            # override the task-record derivation by owner order, so the source
            # reports unavailable and the fallback prevails.
            $src.state = 'unreadable'
            return [PSCustomObject]$out
        }
        $counters['tool_loop_tasks'] = [int]$loopTasks.Count
        $owned = @()
        foreach ($k in @($counters.Keys)) { $owned += [string]$k }
        $src.counters_derived = [object[]]@($owned)
        $out.ok = $true
        return [PSCustomObject]$out
    }
    catch { $src.state = 'unreadable'; return [PSCustomObject]$out }
}

function Measure-EvolutionTelemetryEvidence {
    <#
    .SYNOPSIS
        Derives the evidence counters from the real OrchestrationEvidenceStore
        reuse-metrics.jsonl. evidence_reused stays unavailable unless the file
        really carries a reuse signal (reuse_hits / reuse_misses). Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$EvidenceMetricsPath = '',
        [int]$MaxLines = 2000,
        [int]$MaxLineBytes = 4096,
        [int]$MaxFileBytes = 4194304
    )
    $byReason = [ordered]@{}
    $counters = [ordered]@{}
    $src = [ordered]@{
        state             = 'not-configured'
        files_examined    = 0
        files_skipped     = 0
        lines_examined    = 0
        lines_skipped     = 0
        reuse_signal      = $false
        truncated         = $false
        skipped_by_reason = $byReason
        counters_derived    = [object[]]@()
    }
    $out = [ordered]@{ ok = $false; counters = $counters; source = $src }
    try {
        if ([string]::IsNullOrWhiteSpace($EvidenceMetricsPath)) { return [PSCustomObject]$out }
        if (-not (Test-Path -LiteralPath $EvidenceMetricsPath -PathType Leaf)) { $src.state = 'absent'; return [PSCustomObject]$out }
        $src.state = 'examined'
        $src.files_examined = 1
        $slot = Read-EvolutionTelemetryJsonLines -Path $EvidenceMetricsPath -MaxLines $MaxLines -MaxLineBytes $MaxLineBytes -MaxFileBytes $MaxFileBytes
        if (-not [bool]$slot.ok) {
            $src.state = 'unreadable'
            $src.files_skipped = 1
            Add-EvolutionTelemetrySkip -Map $byReason -Reason ([string]$slot.reason)
            return [PSCustomObject]$out
        }
        $src.lines_examined = ([int]$slot.examined)
        $src.lines_skipped = ([int]$slot.skipped)
        if ([bool]$slot.truncated) { $src.truncated = $true }
        foreach ($k in @($slot.skipped_by_reason.Keys)) { Add-EvolutionTelemetrySkip -Map $byReason -Reason ([string]$k) -Count ([int]$slot.skipped_by_reason[$k]) }
        $created = 0
        $hits = 0
        $signal = $false
        foreach ($row in @($slot.lines)) {
            $metric = ([string](Get-EvolutionValue $row 'metric' '')).Trim()
            if ($metric -ceq 'records_created') { $created++ }
            elseif ($metric -ceq 'reuse_hits') { $hits++; $signal = $true }
            elseif ($metric -ceq 'reuse_misses') { $signal = $true }
        }
        $src.reuse_signal = [bool]$signal
        $counters['evidence_available'] = [int]$created
        if ($signal) { $counters['evidence_reused'] = [int]$hits }
        $owned = @()
        foreach ($k in @($counters.Keys)) { $owned += [string]$k }
        $src.counters_derived = [object[]]@($owned)
        $out.ok = $true
        return [PSCustomObject]$out
    }
    catch { $src.state = 'unreadable'; return [PSCustomObject]$out }
}

# ---------- output ----------

function Get-EvolutionTelemetryRecordText {
    <#
    .SYNOPSIS
        Serializes the record to one compact JSON line (LF terminated, budget
        counted with the LF). Returns @{ok; line; bytes; reason}. Never throws.
    #>
    [CmdletBinding()]
    param($Record, [int]$MaxLineBytes = 4096)
    $out = [ordered]@{ ok = $false; line = ''; bytes = 0; reason = 'EVOLUTION_TELEMETRY_SERIALIZE' }
    try {
        $text = ''
        try { $text = (ConvertTo-Json -InputObject $Record -Depth 6 -Compress) }
        catch { return [PSCustomObject]$out }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]$out }
        $line = ($text + "`n")
        $bytes = [Text.Encoding]::UTF8.GetByteCount($line)
        $out.bytes = [long]$bytes
        if ($bytes -gt [long]$MaxLineBytes) { $out.ok = $false; $out.reason = 'EVOLUTION_TELEMETRY_LINE_CAP'; return [PSCustomObject]$out }
        $out.ok = $true
        $out.reason = ''
        $out.line = $line
        return [PSCustomObject]$out
    }
    catch { return [PSCustomObject]$out }
}

function Add-EvolutionTelemetryLine {
    <#
    .SYNOPSIS
        Appends one bounded line to the daily telemetry file. Measure AND
        append happen through the SAME exclusive (FileShare.None) handle, so a
        cross-process writer cannot slip past the cap accounting; a contended
        handle is a silent skip. Returns @{written; state; error}. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Line,
        [int]$MaxFileBytes = 4194304
    )
    $out = [ordered]@{ written = $false; state = 'not-requested'; error = ''; file = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($OutDir)) { return [PSCustomObject]$out }
        try { if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { [void][IO.Directory]::CreateDirectory($OutDir) } }
        catch { $out.state = 'refused-unwritable-dir'; $out.error = 'EVOLUTION_TELEMETRY_WRITE_FAILED'; return [PSCustomObject]$out }
        $path = Join-Path $OutDir $FileName
        $out.file = $FileName
        $bytes = [Text.Encoding]::UTF8.GetBytes($Line)
        $stream = $null
        try { $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch { $out.state = 'refused-locked'; return [PSCustomObject]$out }
        try {
            $cap = [long]$MaxFileBytes
            if ($cap -lt 1) { $cap = 1 }
            # Same handle: length is measured against the append target we hold.
            if (([long]$stream.Length + [long]$bytes.Length) -gt $cap) { $out.state = 'refused-file-cap'; $out.error = 'EVOLUTION_TELEMETRY_FILE_CAP'; return [PSCustomObject]$out }
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $out.written = $true
            $out.state = 'appended'
            return [PSCustomObject]$out
        }
        finally { try { if ($null -ne $stream) { $stream.Dispose() } } catch { } }
    }
    catch { $out.state = 'refused-write-failed'; $out.error = 'EVOLUTION_TELEMETRY_WRITE_FAILED'; return [PSCustomObject]$out }
}

# ---------- public API ----------

function Invoke-OrchestrationTelemetryProduction {
    <#
    .SYNOPSIS
        Observational telemetry production (Phase 41 slice 2). Reads the real
        kernel task records, watchdog telemetry and evidence metrics, derives
        the policy-declared counters, and - only with an explicit -OutDir -
        appends one bounded JSONL line consumable by
        Get-OrchestrationEvolutionSignals.
    .PARAMETER Policy
        Policy document (ordered map or PSCustomObject). Empty resolves the
        repo default source/registry/evolution-policy.json through the slice-1
        loader; a missing/invalid policy fails closed
        (EVOLUTION_POLICY_UNAVAILABLE / EVOLUTION_POLICY_MALFORMED /
        EVOLUTION_POLICY_INVALID) and is never replaced by in-code defaults.
    .PARAMETER TasksDir
        Kernel task-record directory (cache/runtime/tasks).
    .PARAMETER WatchdogDir
        Optional watchdog-*.jsonl directory.
    .PARAMETER EvidenceMetricsPath
        Optional OrchestrationEvidenceStore reuse-metrics.jsonl path.
    .PARAMETER OutDir
        Optional output directory. Omitted => record-only, ZERO writes.
    .PARAMETER Now
        Optional injected instant for generated_at. An unparsable value falls
        back to internal UTC and the record carries clock_note.
    .PARAMETER MaxTaskFiles
        Cap on task records examined (default 200).
    .OUTPUTS
        @{ok; error; record; counters; unavailable; generated_at; written;
        write_state; write_error; out_file; line_bytes; redacted}. Expected
        domain errors are returned, never thrown.
    .EXAMPLE
        Invoke-OrchestrationTelemetryProduction -Policy $p -TasksDir $tasks
    #>
    [CmdletBinding()]
    param(
        $Policy,
        [Parameter(Mandatory = $true)][string]$TasksDir,
        [string]$WatchdogDir = '',
        [string]$EvidenceMetricsPath = '',
        [string]$OutDir = '',
        $Now = $null,
        [int]$MaxTaskFiles = 200
    )
    try {
        # Lazy dependency: reuse the slice-1 helpers instead of duplicating
        # them. Dot-sourced HERE (this function's scope) so the definitions
        # stay visible for the whole production.
        if (-not (Test-EvolutionTelemetryLoopLoaded)) {
            $dep = Join-Path $PSScriptRoot 'OrchestrationEvolutionLoop.ps1'
            if (-not (Test-Path -LiteralPath $dep -PathType Leaf)) { return (New-EvolutionTelemetryError -Code 'EVOLUTION_TELEMETRY_POLICY_UNAVAILABLE') }
            . $dep
            if (-not (Test-EvolutionTelemetryLoopLoaded)) { return (New-EvolutionTelemetryError -Code 'EVOLUTION_TELEMETRY_POLICY_UNAVAILABLE') }
        }
        $pol = $Policy
        if ($null -eq $pol) {
            $resolved = Resolve-EvolutionPolicy -PolicyPath '' -RepoRoot ''
            if (-not [bool]$resolved.ok) { return $resolved }
            $pol = $resolved.policy
        }
        else {
            $doc = ConvertTo-EvolutionOrdered -Node $pol
            if (-not ($doc -is [System.Collections.IDictionary])) { return (New-EvolutionTelemetryError -Code 'EVOLUTION_POLICY_MALFORMED') }
            if (-not (Test-EvolutionPolicyShape -Policy $doc)) { return (New-EvolutionTelemetryError -Code 'EVOLUTION_POLICY_INVALID') }
            $pol = $doc
        }
        $declared = @(Get-EvolutionTelemetryDeclaredCounters -Policy $pol)
        if ($declared.Count -eq 0) { return (New-EvolutionTelemetryError -Code 'EVOLUTION_POLICY_INVALID') }
        foreach ($mk in @($script:EvolutionTelemetryMetadataKeys)) {
            if (@($declared) -ccontains [string]$mk) {
                return (New-EvolutionTelemetryError -Code 'EVOLUTION_TELEMETRY_METADATA_COLLISION' -Extra @{ key = [string]$mk })
            }
        }
        $maxRecords = (Get-EvolutionPolicyCap -Policy $pol -Name 'max_telemetry_records' -Fallback 2000)
        $maxLineBytes = (Get-EvolutionPolicyCap -Policy $pol -Name 'max_telemetry_line_bytes' -Fallback 4096)
        $maxFileBytes = (Get-EvolutionPolicyCap -Policy $pol -Name 'max_telemetry_file_bytes' -Fallback 4194304)
        $maxMetric = (Get-EvolutionPolicyCap -Policy $pol -Name 'max_metric_value' -Fallback 1000000)
        $maxFiles = (Get-EvolutionPolicyCap -Policy $pol -Name 'max_telemetry_files' -Fallback 64)

        $tasks = Measure-EvolutionTelemetryTasks -TasksDir $TasksDir -MaxTaskFiles $MaxTaskFiles -MaxRecordBytes $maxFileBytes
        $watchdog = Measure-EvolutionTelemetryWatchdog -WatchdogDir $WatchdogDir -MaxFiles $maxFiles -MaxLines $maxRecords -MaxLineBytes $maxLineBytes -MaxFileBytes $maxFileBytes
        $evidence = Measure-EvolutionTelemetryEvidence -EvidenceMetricsPath $EvidenceMetricsPath -MaxLines $maxRecords -MaxLineBytes $maxLineBytes -MaxFileBytes $maxFileBytes
        $byName = [ordered]@{
            'tasks'    = $tasks
            'watchdog' = $watchdog
            'evidence' = $evidence
        }

        # Resolve each declared counter through its declared owner order. No
        # value is ever summed across two identity spaces.
        $resolved = [ordered]@{}
        $reasons = [ordered]@{}
        $ownership = [ordered]@{}
        foreach ($name in $declared) {
            $key = [string]$name
            $owners = $null
            if ($script:EvolutionTelemetryCounterOwners.Contains($key)) { $owners = @($script:EvolutionTelemetryCounterOwners[$key]) }
            $resolvedOne = $false
            if ($null -ne $owners) {
                foreach ($o in $owners) {
                    $slot = $byName[[string]$o]
                    if ($null -eq $slot) { continue }
                    if (-not [bool]$slot.ok) { continue }
                    $cs = $slot.counters
                    if (($cs -is [System.Collections.IDictionary]) -and $cs.Contains($key)) {
                        $v = $cs[$key]
                        if (-not (Test-EvolutionStrictInt -Value $v -Min 0 -Max $maxMetric)) { continue }
                        $resolved[$key] = [int]$v
                        $ownership[$key] = [string]$o
                        $resolvedOne = $true
                        break
                    }
                }
            }
            if ($resolvedOne) { continue }
            if ($script:EvolutionTelemetryNoSourceReasons.Contains($key)) {
                $reasons[$key] = [string]$script:EvolutionTelemetryNoSourceReasons[$key]
                continue
            }
            if ($null -eq $owners) { $reasons[$key] = 'counter-not-producible-by-any-source'; continue }
            $why = 'no-source-configured'
            foreach ($o in $owners) {
                $slot = $byName[[string]$o]
                if ($null -ne $slot) {
                    $st = ([string]$slot.source.state)
                    if ($st -ceq 'absent') { $why = 'source-absent'; break }
                    if ($st -ceq 'unreadable') { $why = 'source-unreadable'; break }
                }
            }
            $reasons[$key] = (Get-EvolutionTelemetrySafeReason -Value $why)
        }

        # injected clock: an unparsable value falls back to internal UTC with a note
        $clockNote = ''
        $instant = $null
        if ($null -ne $Now) {
            $instant = ConvertTo-EvolutionTelemetryInstant $Now
            if ($null -eq $instant) { $clockNote = 'invalid-now-fallback-to-internal-utc' }
        }
        $generatedAt = ''
        if ($null -ne $instant) { $generatedAt = ($instant.ToString('o')) }
        else { $generatedAt = (Get-EvolutionUtcNowText -AtUtc $null) }
        $stampForName = $generatedAt
        $nameStamp = ''
        $parsedStamp = ConvertTo-EvolutionTelemetryInstant $stampForName
        if ($null -ne $parsedStamp) { $nameStamp = ($parsedStamp.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)) }

        $unavail = New-Object System.Collections.ArrayList
        foreach ($name in $declared) {
            $key = [string]$name
            if ($resolved.Contains($key)) { continue }
            [void]$unavail.Add([ordered]@{ counter = $key; reason = (Get-EvolutionTelemetrySafeReason -Value ([string]$reasons[$key])) })
        }
        $sourcesOut = [ordered]@{
            'tasks'    = $tasks.source
            'watchdog' = $watchdog.source
            'evidence' = $evidence.source
        }

        $record = [ordered]@{}
        $record['record_type'] = 'EVOLUTION_TELEMETRY'
        $record['generated_at'] = $generatedAt
        $record['producer'] = $script:EvolutionTelemetryProducerTag
        $record['policy_version'] = [int](Get-EvolutionValue $pol 'version' 1)
        $record['redacted'] = $true
        foreach ($name in $declared) {
            $key = [string]$name
            if (-not $resolved.Contains($key)) { continue }
            $record[$key] = [int]$resolved[$key]
        }
        $record['unavailable_counters'] = [object[]]@($unavail.ToArray())
        $record['sources'] = $sourcesOut
        $record['clock_note'] = [string]$clockNote

        $serialized = Get-EvolutionTelemetryRecordText -Record $record -MaxLineBytes $maxLineBytes
        $writeState = 'record-only'
        $writeError = ''
        $written = $false
        $outFile = ''
        if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
            $outFile = ('evolution-telemetry-' + $nameStamp + '.jsonl')
            if (-not [bool]$serialized.ok) {
                $writeState = 'refused-line-cap'
                $writeError = ([string]$serialized.reason)
            }
            else {
                $added = Add-EvolutionTelemetryLine -OutDir $OutDir -FileName $outFile -Line ([string]$serialized.line) -MaxFileBytes $maxFileBytes
                $writeState = ([string]$added.state)
                $writeError = ([string]$added.error)
                $written = [bool]$added.written
            }
        }
        $counterView = [ordered]@{}
        foreach ($name in $declared) {
            $key = [string]$name
            if ($resolved.Contains($key)) { $counterView[$key] = [int]$resolved[$key] }
        }
        $unavailableView = [ordered]@{}
        foreach ($u in @($unavail.ToArray())) { $unavailableView[[string]$u.counter] = [string]$u.reason }
        $ownershipView = [ordered]@{}
        foreach ($k in @($ownership.Keys)) { $ownershipView[[string]$k] = [string]$ownership[$k] }
        return [PSCustomObject]@{
            ok            = $true
            error         = ''
            record        = [PSCustomObject]$record
            counters      = [PSCustomObject]$counterView
            unavailable   = [PSCustomObject]$unavailableView
            ownership     = [PSCustomObject]$ownershipView
            generated_at  = $generatedAt
            written       = [bool]$written
            write_state   = [string]$writeState
            write_error   = [string]$writeError
            out_file      = [string]$outFile
            line_bytes    = [long]$serialized.bytes
            redacted      = $true
            observation_only = $true
        }
    }
    catch { return (New-EvolutionTelemetryError -Code 'EVOLUTION_TELEMETRY_PRODUCTION_FAILED') }
}