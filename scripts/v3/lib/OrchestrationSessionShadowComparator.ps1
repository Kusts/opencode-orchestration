<#
.SYNOPSIS
    Pure read-only comparator between native OpenCode V2 sessions and local catalog bindings.
.DESCRIPTION
    No state mutation. Classifies each session as MATCH, NATIVE_ONLY, LOCAL_ONLY,
    FIELD_MISMATCH, NOT_COMPARABLE or QUERY_ERROR.
#>
[CmdletBinding()]
param()

function ConvertTo-ShadowTimestampMs {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [long] -or $Value -is [int] -or $Value -is [System.Int64] -or $Value -is [System.Int32]) {
        $v = [long]$Value
        # heuristic: seconds vs ms
        if ($v -lt 10000000000) { return ($v * 1000) }
        return $v
    }
    try {
        $dt = [DateTime]::Parse([string]$Value).ToUniversalTime()
        return [long]([DateTimeOffset]$dt).ToUnixTimeMilliseconds()
    } catch {
        return $null
    }
}

function Compare-SessionCatalogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$LocalBindings,
        [Parameter(Mandatory=$true)]$NativeResult,
        [string]$ProjectFilter = '',
        [int]$NativeLimit = 0
    )
    $report = [ordered]@{
        status = 'ok'
        local_count = 0
        native_count = 0
        comparable_ids = 0
        matches = 0
        field_mismatches = 0
        native_only = 0
        local_only = 0
        not_comparable = 0
        query_error = $false
        truncated = $false
        classifications = @()
        metrics = [ordered]@{}
    }

    # Handle query error
    if ($NativeResult -is [pscustomobject] -and $NativeResult.PSObject.Properties['ok'] -and -not $NativeResult.ok) {
        $report.query_error = $true
        $report.status = 'query_error'
        # still count locals
        $locals = @($LocalBindings)
        $report.local_count = $locals.Count
        foreach ($lb in $locals) {
            $report.classifications += [pscustomobject]@{ id = [string]$lb.session_id; classification = 'LOCAL_ONLY'; reason = 'native query failed' }
            $report.local_only++
        }
        return [pscustomobject]$report
    }

    $nativeSessions = @()
    if ($NativeResult -is [pscustomobject] -and $NativeResult.PSObject.Properties['sessions']) {
        $nativeSessions = @($NativeResult.sessions)
    } elseif ($NativeResult -is [array]) {
        $nativeSessions = @($NativeResult)
    }
    $locals = @($LocalBindings)

    $report.local_count = $locals.Count
    $report.native_count = $nativeSessions.Count

    # truncation check
    if ($NativeLimit -gt 0 -and $nativeSessions.Count -ge $NativeLimit) {
        $report.truncated = $true
    }

    # duplicate id detection
    $nativeIds = @($nativeSessions | ForEach-Object { [string]$_.id })
    $localIds = @($locals | ForEach-Object { [string]$_.session_id })
    $dupNative = ($nativeIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0
    $dupLocal = ($localIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0
    if ($dupNative -or $dupLocal) {
        $report.not_comparable = ($locals.Count + $nativeSessions.Count)
        $report.status = 'not_comparable'
        $report.metrics.note = 'duplicate id detected'
        return [pscustomobject]$report
    }

    $nativeMap = @{}
    foreach ($ns in $nativeSessions) { $nativeMap[[string]$ns.id] = $ns }
    $localMap = @{}
    foreach ($lb in $locals) { $localMap[[string]$lb.session_id] = $lb }

    $allIds = @($nativeIds + $localIds | Select-Object -Unique)

    foreach ($id in $allIds) {
        $inNative = $nativeMap.ContainsKey($id)
        $inLocal = $localMap.ContainsKey($id)
        if ($inNative -and $inLocal) {
            $report.comparable_ids++
            $ns = $nativeMap[$id]
            $lb = $localMap[$id]
            $mismatch = $false
            $reasons = @()
            # directory/project comparison
            if (-not [string]::IsNullOrWhiteSpace([string]$lb.directory) -and -not [string]::IsNullOrWhiteSpace([string]$ns.directory)) {
                if ([string]$lb.directory -ne [string]$ns.directory) { $mismatch = $true; $reasons += 'directory' }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$lb.project) -and -not [string]::IsNullOrWhiteSpace([string]$ns.projectId)) {
                if ([string]$lb.project -ne [string]$ns.projectId) { $mismatch = $true; $reasons += 'project' }
            }
            # timestamp normalization check
            $lt = ConvertTo-ShadowTimestampMs $lb.updated_at
            $nt = ConvertTo-ShadowTimestampMs $ns.updated
            if ($null -ne $lt -and $null -ne $nt) {
                # allow 5s tolerance
                if ([Math]::Abs($lt - $nt) -gt 5000) { $mismatch = $true; $reasons += 'timestamp' }
            }
            if ($mismatch) {
                $report.field_mismatches++
                $report.classifications += [pscustomobject]@{ id = $id; classification = 'FIELD_MISMATCH'; fields = ($reasons -join ',') }
            } else {
                $report.matches++
                $report.classifications += [pscustomobject]@{ id = $id; classification = 'MATCH'; fields = '' }
            }
        } elseif ($inNative) {
            $report.native_only++
            $report.classifications += [pscustomobject]@{ id = $id; classification = 'NATIVE_ONLY'; reason = 'not in local catalog' }
        } else {
            $report.local_only++
            $report.classifications += [pscustomobject]@{ id = $id; classification = 'LOCAL_ONLY'; reason = 'not in native sample' }
        }
    }

    if ($report.truncated) {
        # downgrade local_only certainty: mark as potentially truncated
        foreach ($c in $report.classifications) {
            if ($c.classification -eq 'LOCAL_ONLY') {
                $c | Add-Member -NotePropertyName note -NotePropertyValue 'native sample may be truncated' -Force
            }
        }
    }

    $report.metrics = [ordered]@{
        local_count = $report.local_count
        native_count = $report.native_count
        comparable_ids = $report.comparable_ids
        matches = $report.matches
        field_mismatches = $report.field_mismatches
        native_only = $report.native_only
        local_only = $report.local_only
        truncated = $report.truncated
    }
    return [pscustomobject]$report
}