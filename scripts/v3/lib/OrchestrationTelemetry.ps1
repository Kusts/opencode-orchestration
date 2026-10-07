<#!
.SYNOPSIS
    V3 Telemetry: read-only aggregation over evidence + goal stores (SPEC v0.1.0 Phase 13, PR-K).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure aggregation,
    fail-open, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: missing stores yield zeros plus a note, and any
    internal failure yields a zeros summary. No network, no process, no
    writes, no grants, no leases. This lib only reads; it never
    persists anything.

    TDR-F13-01: Get-OrchestrationTelemetrySummary maps
    -EvidenceStoreDir / -GoalStoreDir to one summary envelope:
    version (=1), reuse (queries/hits/misses/misses_by_reason plus
    reuse_rate = hits/queries when queries > 0 else $null, computed
    via Get-OrchestrationEvidenceMetrics from the sibling evidence
    store lib, lazily dot-sourced), goals (goals_total plus
    goal_states, counting only VALID *.json goal files by their state
    field; each file is validated via ConvertTo-GKGoalRecord from the
    sibling goal kernel lib, lazily dot-sourced, with a strict field
    fallback when the kernel is unavailable; invalid files count in
    goals_invalid and never in states/total), decisions (the
    DecisionProvider lib does NOT persist, so this honestly reports
    persisted=$false with a note pointing at future evidence
    reuse_metrics telemetry, inventing nothing), truncated ([bool],
    true when the file cap or an oversize skip made the scan partial)
    plus note ('truncated-file-cap' when the cap is hit,
    'skipped-oversize' when a >1MiB file is skipped, 'goals-invalid'
    when any invalid file is seen; never '' when partial), and
    timestamp. Missing dirs are fail-open (zeros + note, never throw).
    -MaxFiles (default 1000) bounds the goal scan; it exists ONLY for
    testability and must keep the default in production. Strict types
    throughout.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-TLMGoalStates {
    [CmdletBinding()]
    param()
    return @('DRAFT', 'ACTIVE', 'PAUSED', 'BLOCKED', 'BUDGET_LIMITED', 'COMPLETED', 'EXHAUSTED', 'CANCELLED')
}

function Get-TLMNonNegativeLong {
    param($Value)
    try {
        if ($Value -is [long]) { if ([long]$Value -ge 0) { return [long]$Value }; return [long]0 }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte]) {
            $n = [long]$Value
            if ($n -ge 0) { return $n }
            return [long]0
        }
        return [long]0
    }
    catch { return [long]0 }
}

function Get-TLMEmptySummary {
    param([string]$Note = '')
    try {
        $reuse = [pscustomobject][ordered]@{
            queries          = [long]0
            hits             = [long]0
            misses           = [long]0
            misses_by_reason = @{}
            reuse_rate       = $null
        }
        $goals = [pscustomobject][ordered]@{
            goals_total = [long]0
            goal_states = @{}
            goals_invalid = [long]0
            truncated = [bool]$false
            note = ''
        }
        $decisions = [pscustomobject][ordered]@{
            persisted = [bool]$false
            note      = 'decision telemetry via evidence reuse_metrics em Fase futura'
        }
        $stamp = ''
        try { $stamp = ([DateTime]::UtcNow.ToString('o')) } catch { $stamp = '' }
        return [pscustomobject][ordered]@{
            version   = [long]1
            reuse     = $reuse
            goals     = $goals
            decisions = $decisions
            timestamp = [string]$stamp
            note      = [string]$Note
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            version   = [long]1
            reuse     = [pscustomobject][ordered]@{ queries = [long]0; hits = [long]0; misses = [long]0; misses_by_reason = @{}; reuse_rate = $null }
            goals     = [pscustomobject][ordered]@{ goals_total = [long]0; goal_states = @{}; goals_invalid = [long]0; truncated = [bool]$false; note = '' }
            decisions = [pscustomobject][ordered]@{ persisted = $false; note = 'decision telemetry via evidence reuse_metrics em Fase futura' }
            timestamp = ''
            note      = 'telemetry-internal'
        }
    }
}

function Test-TLMFallbackGoalValid {
    # Strict field fallback used ONLY when ConvertTo-GKGoalRecord from
    # the goal kernel lib is unavailable: goal_id must be a valid
    # non-empty string, state must be in the known set, revision must
    # be an integral numeric type ([long]/[int]/[int16]/[short]/[byte],
    # mirroring Get-GKGoalLong) >= 1. Strings, booleans, floats and
    # arrays are invalid: no coercion is attempted.
    param($Goal)
    try {
        $gid = $null
        $stRaw = $null
        $revRaw = $null
        if ($Goal -is [System.Collections.IDictionary]) {
            if ($Goal.Contains('goal_id')) { $gid = $Goal['goal_id'] }
            if ($Goal.Contains('state')) { $stRaw = $Goal['state'] }
            if ($Goal.Contains('revision')) { $revRaw = $Goal['revision'] }
        }
        else {
            $p = $Goal.PSObject.Properties['goal_id']
            if ($null -ne $p) { $gid = $p.Value }
            $p = $Goal.PSObject.Properties['state']
            if ($null -ne $p) { $stRaw = $p.Value }
            $p = $Goal.PSObject.Properties['revision']
            if ($null -ne $p) { $revRaw = $p.Value }
        }
        if (-not ($gid -is [string])) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$gid)) { return $false }
        if (-not ([string]$gid -cmatch '^[A-Za-z0-9._:-]{1,64}$')) { return $false }
        $st = ([string]$stRaw).Trim().ToUpperInvariant()
        if (@(Get-TLMGoalStates) -cnotcontains $st) { return $false }
        if ($null -eq $revRaw) { return $false }
        if ($revRaw -is [long]) { $rev = [long]$revRaw }
        elseif ($revRaw -is [int] -or $revRaw -is [int16] -or $revRaw -is [short] -or $revRaw -is [byte]) { $rev = [long]$revRaw }
        else { return $false }
        if ($rev -lt 1) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-TLMGoalState {
    # Returns the validated state string, or '' when the record is
    # invalid. Prefers ConvertTo-GKGoalRecord (goal kernel, lazy
    # dot-source); falls back to the strict field check above.
    param($Goal)
    try {
        $cmd = Get-Command ConvertTo-GKGoalRecord -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            $gk = Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1'
            if (Test-Path -LiteralPath $gk -PathType Leaf) {
                try { . $gk } catch { }
            }
            $cmd = Get-Command ConvertTo-GKGoalRecord -ErrorAction SilentlyContinue
        }
        if ($null -ne $cmd) {
            $rec = ConvertTo-GKGoalRecord $Goal
            if ($null -eq $rec) { return '' }
            return ([string]$rec['state'])
        }
        if (-not (Test-TLMFallbackGoalValid $Goal)) { return '' }
        if ($Goal -is [System.Collections.IDictionary]) {
            return (([string]$Goal['state']).Trim().ToUpperInvariant())
        }
        return (([string]$Goal.PSObject.Properties['state'].Value).Trim().ToUpperInvariant())
    }
    catch { return '' }
}

function Get-OrchestrationTelemetrySummary {
    <#
    .SYNOPSIS
        Read-only telemetry aggregation (TDR-F13-01).
    .DESCRIPTION
        Aggregates evidence reuse metrics and goal-store state counts
        into one summary envelope. Fail-open: missing or unreadable
        stores yield zeros plus a note, never a throw. Never returns
        $null.
    #>
    [CmdletBinding()]
    param(
        [string]$EvidenceStoreDir = '',
        [string]$GoalStoreDir = '',
        [int]$MaxFiles = 1000
    )
    try {
        $cmd = Get-Command Get-OrchestrationEvidenceMetrics -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            $sib = Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1'
            if (Test-Path -LiteralPath $sib -PathType Leaf) {
                try { . $sib } catch { }
            }
        }
        $notes = New-Object System.Collections.ArrayList
        $queries = [long]0
        $hits = [long]0
        $misses = [long]0
        $byReason = @{}
        $evDir = ([string]$EvidenceStoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($evDir) -or (-not (Test-Path -LiteralPath $evDir -PathType Container))) {
            [void]$notes.Add('evidence-store-missing')
        }
        else {
            try {
                $m = Get-OrchestrationEvidenceMetrics -StoreDir $evDir
                if ($null -ne $m) {
                    $queries = Get-TLMNonNegativeLong $m.reuse_queries
                    $hits = Get-TLMNonNegativeLong $m.reuse_hits
                    $misses = Get-TLMNonNegativeLong $m.reuse_misses
                    $raw = $null
                    try { $raw = $m.misses_by_reason } catch { $raw = $null }
                    if ($null -ne $raw) {
                        if ($raw -is [System.Collections.IDictionary]) {
                            foreach ($k in @($raw.Keys)) {
                                $ks = ([string]$k).Trim()
                                if ([string]::IsNullOrWhiteSpace($ks)) { continue }
                                $byReason[$ks] = Get-TLMNonNegativeLong $raw[$k]
                            }
                        }
                        elseif ($raw -is [pscustomobject]) {
                            foreach ($p in @($raw.PSObject.Properties)) {
                                $ks = ([string]$p.Name).Trim()
                                if ([string]::IsNullOrWhiteSpace($ks)) { continue }
                                $byReason[$ks] = Get-TLMNonNegativeLong $p.Value
                            }
                        }
                    }
                }
            }
            catch {
                [void]$notes.Add('evidence-metrics-unavailable')
            }
        }
        $rate = $null
        if ($queries -gt 0) {
            try { $rate = ([double]$hits / [double]$queries) } catch { $rate = $null }
        }
        $reuse = [pscustomobject][ordered]@{
            queries          = [long]$queries
            hits             = [long]$hits
            misses           = [long]$misses
            misses_by_reason = $byReason
            reuse_rate       = $rate
        }
        $total = [long]0
        $states = @{}
        $invalid = [long]0
        $truncated = [bool]$false
        $goalNotes = New-Object System.Collections.ArrayList
        $skippedOversize = [bool]$false
        $goalDir = ([string]$GoalStoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($goalDir) -or (-not (Test-Path -LiteralPath $goalDir -PathType Container))) {
            [void]$notes.Add('goal-store-missing')
        }
        else {
            try {
                $cap = [int]$MaxFiles
                if ($cap -lt 1) { $cap = 1 }
                $probe = @(Get-ChildItem -LiteralPath $goalDir -Filter '*.json' -File -ErrorAction Stop | Select-Object -First ($cap + 1))
                $files = @($probe)
                if (@($probe).Count -gt $cap) {
                    $truncated = [bool]$true
                    $files = @(@($probe)[0..($cap - 1)])
                    [void]$goalNotes.Add('truncated-file-cap')
                }
                foreach ($f in $files) {
                    try {
                        if ($f.Length -gt 1048576) {
                            $skippedOversize = [bool]$true
                            continue
                        }
                        $g = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
                        $st = Get-TLMGoalState $g
                        if ([string]::IsNullOrWhiteSpace($st)) {
                            $invalid++
                            continue
                        }
                        if (@(Get-TLMGoalStates) -cnotcontains $st) {
                            $invalid++
                            continue
                        }
                        $total++
                        if (-not $states.ContainsKey($st)) { $states[$st] = [long]0 }
                        $states[$st] = [long]$states[$st] + 1
                    }
                    catch {
                        $invalid++
                        continue
                    }
                }
                if ($skippedOversize) {
                    $truncated = [bool]$true
                    [void]$goalNotes.Add('skipped-oversize')
                }
                if ($invalid -gt 0) { [void]$goalNotes.Add('goals-invalid') }
                foreach ($gn in @($goalNotes)) { [void]$notes.Add([string]$gn) }
            }
            catch {
                [void]$notes.Add('goal-store-unreadable')
            }
        }
        $goals = [pscustomobject][ordered]@{
            goals_total = [long]$total
            goal_states = $states
            goals_invalid = [long]$invalid
            truncated = [bool]$truncated
            note = [string]($goalNotes -join ';')
        }
        $decisions = [pscustomobject][ordered]@{
            persisted = [bool]$false
            note      = 'decision telemetry via evidence reuse_metrics em Fase futura'
        }
        $stamp = ''
        try { $stamp = ([DateTime]::UtcNow.ToString('o')) } catch { $stamp = '' }
        return [pscustomobject][ordered]@{
            version   = [long]1
            reuse     = $reuse
            goals     = $goals
            decisions = $decisions
            timestamp = [string]$stamp
            note      = [string]($notes -join ';')
        }
    }
    catch {
        return (Get-TLMEmptySummary -Note 'telemetry-internal')
    }
}
