<#!
.SYNOPSIS
    V3 Goal Progress Delta: pure progress-change scoring (SPEC v0.1.0 Phase 8).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure functions,
    fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: every failure returns a fail-closed envelope
    with meaningful=$false. No network, no process, no store, no
    kernel, no dispatch. This lib only scores deltas; loop-guard
    wiring belongs to a later phase (never here).

    TDR-F8 (progress): Get-OrchestrationGoalProgressDelta maps a
    previous/current metric snapshot pair to one delta envelope:
    delta, meaningful, stagnation_count, strategy_change_required.
    Metrics per snapshot: satisfied, total, failed_tests, open_p1,
    blockers. Strict types: every metric must be an integral scalar;
    non-scalar (or missing) input fails closed with meaningful=$false
    and reason 'invalid-input'. Improvement per metric: satisfied up,
    failed_tests / open_p1 / blockers down (total is scope, never
    progress by itself). meaningful=$true when at least one metric
    improved; change for the worse only yields meaningful=$false with
    reason 'regressed'; no change yields meaningful=$false with reason
    'no-change'. stagnation_count is the input count + 1 when not
    meaningful, else 0. strategy_change_required when stagnation
    reaches the documented threshold of 3 (future policy may own it).
#>
[CmdletBinding()]
param()

$script:GPStagnationThreshold = 3

function Get-GPDField {
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                $v = $Object[$Name]
                if ($null -eq $v) { return $null }
                # Comma wrap: a singleton array must reach the caller as
                # an array (type gate rejects it), never unrolled to scalar.
                return ,$v
            }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) {
            $v = $p.Value
            if ($null -eq $v) { return $null }
            return ,$v
        }
        return $null
    }
    catch { return $null }
}

function Get-GPDMetric {
    param($Value)
    try {
        if ($null -eq $Value) { return $null }
        if ($Value -is [long]) { return [long]$Value }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte]) {
            return [long]$Value
        }
        return $null
    }
    catch { return $null }
}

function Get-GPDStagnationInput {
    param($Value)
    try {
        $n = Get-GPDMetric $Value
        if ($null -eq $n) { return [long]0 }
        if ([long]$n -lt 0) { return [long]0 }
        return [long]$n
    }
    catch { return [long]0 }
}

function Get-GPDBumpedStagnation {
    param([long]$StagnationInput = 0)
    try {
        # Saturated increment: at or above MaxValue - 1 the count pins at
        # MaxValue instead of throwing on integral overflow (fail-closed:
        # the strategy-change gate stays on, never a throw).
        if ([long]$StagnationInput -ge ([long]([long]::MaxValue - 1))) { return [long]::MaxValue }
        return ([long]$StagnationInput + 1)
    }
    catch { return [long]::MaxValue }
}

function New-GPProgressDelta {
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Reason = '',
        [long]$SatisfiedDiff = 0,
        [long]$TotalDiff = 0,
        [long]$FailedDiff = 0,
        [long]$OpenDiff = 0,
        [long]$BlockersDiff = 0,
        [bool]$Meaningful = $false,
        [long]$StagnationCount = 0
    )
    try {
        $r = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) {
            if ($Ok) { $r = 'improved' } else { $r = 'invalid-input' }
        }
        $stag = [long]$StagnationCount
        if ($stag -lt 0) { $stag = 0 }
        return [PSCustomObject][ordered]@{
            ok                       = [bool]$Ok
            reason                   = $r
            delta                    = [PSCustomObject][ordered]@{
                satisfied_diff   = [long]$SatisfiedDiff
                total_diff       = [long]$TotalDiff
                failed_tests_diff = [long]$FailedDiff
                open_p1_diff     = [long]$OpenDiff
                blockers_diff    = [long]$BlockersDiff
            }
            meaningful               = [bool]$Meaningful
            stagnation_count         = $stag
            strategy_change_required = ([bool]($stag -ge $script:GPStagnationThreshold))
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            ok                       = $false
            reason                   = 'invalid-input'
            delta                    = [PSCustomObject][ordered]@{
                satisfied_diff   = [long]0
                total_diff       = [long]0
                failed_tests_diff = [long]0
                open_p1_diff     = [long]0
                blockers_diff    = [long]0
            }
            meaningful               = $false
            stagnation_count         = [long]0
            strategy_change_required = $false
        }
    }
}

function Get-OrchestrationGoalProgressDelta {
    <#
    .SYNOPSIS
        Pure progress-delta scoring (TDR-F8).
    .DESCRIPTION
        Maps -Previous / -Current metric snapshots (hashtable or
        PSObject with satisfied, total, failed_tests, open_p1,
        blockers as integral scalars) plus the incoming
        -StagnationCount to one delta envelope. Strict types:
        non-scalar or missing metrics fail closed (meaningful=$false,
        reason 'invalid-input', stagnation input + 1). Never throws,
        never returns $null.
    #>
    [CmdletBinding()]
    param($Previous = $null, $Current = $null, $StagnationCount = 0)
    try {
        $isObj = {
            param($v)
            return (($null -ne $v) -and (($v -is [System.Collections.IDictionary]) -or ($v -is [pscustomobject])))
        }
        $stagIn = Get-GPDStagnationInput $StagnationCount
        if ((-not (& $isObj $Previous)) -or (-not (& $isObj $Current))) {
            return (New-GPProgressDelta -Ok $false -Reason 'invalid-input' -Meaningful $false -StagnationCount (Get-GPDBumpedStagnation $stagIn))
        }
        $names = @('satisfied', 'total', 'failed_tests', 'open_p1', 'blockers')
        $prev = @{}
        $curr = @{}
        foreach ($name in $names) {
            $pv = Get-GPDMetric (Get-GPDField $Previous $name)
            $cv = Get-GPDMetric (Get-GPDField $Current $name)
            if (($null -eq $pv) -or ($null -eq $cv)) {
                return (New-GPProgressDelta -Ok $false -Reason 'invalid-input' -Meaningful $false -StagnationCount (Get-GPDBumpedStagnation $stagIn))
            }
            $prev[$name] = [long]$pv
            $curr[$name] = [long]$cv
        }
        $satDiff = [long]$curr['satisfied'] - [long]$prev['satisfied']
        $totDiff = [long]$curr['total'] - [long]$prev['total']
        $failDiff = [long]$curr['failed_tests'] - [long]$prev['failed_tests']
        $openDiff = [long]$curr['open_p1'] - [long]$prev['open_p1']
        $blockDiff = [long]$curr['blockers'] - [long]$prev['blockers']
        $improved = (($satDiff -gt 0) -or ($failDiff -lt 0) -or ($openDiff -lt 0) -or ($blockDiff -lt 0))
        if ($improved) {
            return (New-GPProgressDelta -Ok $true -Reason 'improved' -SatisfiedDiff $satDiff -TotalDiff $totDiff -FailedDiff $failDiff -OpenDiff $openDiff -BlockersDiff $blockDiff -Meaningful $true -StagnationCount 0)
        }
        $changed = (($satDiff -ne 0) -or ($totDiff -ne 0) -or ($failDiff -ne 0) -or ($openDiff -ne 0) -or ($blockDiff -ne 0))
        if ($changed) {
            return (New-GPProgressDelta -Ok $true -Reason 'regressed' -SatisfiedDiff $satDiff -TotalDiff $totDiff -FailedDiff $failDiff -OpenDiff $openDiff -BlockersDiff $blockDiff -Meaningful $false -StagnationCount (Get-GPDBumpedStagnation $stagIn))
        }
        return (New-GPProgressDelta -Ok $true -Reason 'no-change' -Meaningful $false -StagnationCount (Get-GPDBumpedStagnation $stagIn))
    }
    catch {
        # Gate-preserving fallback: never reset to a hardcoded count.
        # Propagate the (clamped) input count, so an input at or above
        # the threshold keeps strategy_change_required on.
        $stagFb = [long]0
        try { $stagFb = Get-GPDStagnationInput $StagnationCount } catch { $stagFb = [long]0 }
        return (New-GPProgressDelta -Ok $false -Reason 'invalid-input' -Meaningful $false -StagnationCount $stagFb)
    }
}
