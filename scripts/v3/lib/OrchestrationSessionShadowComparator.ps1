<#
.SYNOPSIS
    Pure read-only comparator between native OpenCode V2 sessions and local catalog bindings.
#>
[CmdletBinding()]
param()

function ConvertTo-ShadowTimestampMs {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [long] -or $Value -is [int] -or $Value -is [System.Int64] -or $Value -is [System.Int32]) {
        $v = [long]$Value
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
        local_candidates = 0
        real_local_bindings = 0
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

    $nativeRaw = @()
    $malformedNative = $false
    if ($NativeResult -is [pscustomobject] -and $NativeResult.PSObject.Properties['sessions']) {
        $nativeRaw = @($NativeResult.sessions)
    } elseif ($NativeResult -is [array]) {
        $nativeRaw = @($NativeResult)
    } else {
        $malformedNative = $true
    }
    if ($malformedNative) {
        $report.not_comparable = @($LocalBindings).Count
        $report.status = 'not_comparable'
        $report.metrics.note = 'native result malformed'
        return [pscustomobject]$report
    }

    # truncation based on raw count before filters
    if ($NativeLimit -gt 0 -and $nativeRaw.Count -ge $NativeLimit) {
        $report.truncated = $true
    }

    # QUERY_ERROR branch
    if ($NativeResult -is [pscustomobject] -and $NativeResult.PSObject.Properties['ok'] -and -not $NativeResult.ok) {
        $report.query_error = $true
        $report.status = 'query_error'
        $locals = @($LocalBindings)
        if (-not [string]::IsNullOrWhiteSpace($ProjectFilter)) {
            $locals = @($locals | Where-Object { [string]$_.project -eq $ProjectFilter })
        }
        $report.local_candidates = @($LocalBindings).Count
        $report.real_local_bindings = $locals.Count
        $report.local_count = $locals.Count
        foreach ($lb in $locals) {
            $report.classifications += [pscustomobject]@{ id = [string]$lb.session_id; classification = 'QUERY_ERROR'; reason = 'native query failed' }
        }
        return [pscustomobject]$report
    }

    # Apply ProjectFilter
    $nativeSessions = $nativeRaw
    $locals = @($LocalBindings)
    if (-not [string]::IsNullOrWhiteSpace($ProjectFilter)) {
        $nativeSessions = @($nativeSessions | Where-Object { [string]$_.projectId -eq $ProjectFilter })
        $locals = @($locals | Where-Object { [string]$_.project -eq $ProjectFilter })
    }

    $report.local_candidates = @($LocalBindings).Count
    # real_local_bindings = those with non-empty session_id
    $realBindings = @($locals | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.session_id) })
    $report.real_local_bindings = $realBindings.Count
    $report.local_count = $locals.Count
    $report.native_count = $nativeSessions.Count

    # duplicate id detection (case-sensitive ordinal)
    $nativeIds = @($nativeSessions | ForEach-Object { [string]$_.id })
    $localIds = @($realBindings | ForEach-Object { [string]$_.session_id })
    $nativeGroup = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)
    foreach ($nid in $nativeIds) { if ($nativeGroup.ContainsKey($nid)) { $nativeGroup[$nid]++ } else { $nativeGroup[$nid] = 1 } }
    $dupNative = ($nativeGroup.Values | Where-Object { $_ -gt 1 }).Count -gt 0
    $localGroup = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::Ordinal)
    foreach ($lid in $localIds) { if ($localGroup.ContainsKey($lid)) { $localGroup[$lid]++ } else { $localGroup[$lid] = 1 } }
    $dupLocal = ($localGroup.Values | Where-Object { $_ -gt 1 }).Count -gt 0
    if ($dupNative -or $dupLocal) {
        $report.not_comparable = ($realBindings.Count + $nativeSessions.Count)
        $report.status = 'not_comparable'
        $report.metrics.note = 'duplicate id detected'
        return [pscustomobject]$report
    }

    # case-sensitive ordinal dictionary
    $nativeMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($ns in $nativeSessions) { $nativeMap[[string]$ns.id] = $ns }
    $localMap = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($lb in $realBindings) { $localMap[[string]$lb.session_id] = $lb }

    $allIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($aid in ($nativeIds + $localIds)) { [void]$allIdSet.Add($aid) }
    $allIds = @($allIdSet)

    foreach ($id in $allIds) {
        $inNative = $nativeMap.ContainsKey($id)
        $inLocal = $localMap.ContainsKey($id)
        if ($inNative -and $inLocal) {
            # NOT_COMPARABLE if missing required data
            $ns = $nativeMap[$id]
            $lb = $localMap[$id]
            if ([string]::IsNullOrWhiteSpace([string]$id) -or [string]::IsNullOrWhiteSpace([string]$lb.directory) -or [string]::IsNullOrWhiteSpace([string]$ns.directory)) {
                $report.not_comparable++
                $report.classifications += [pscustomobject]@{ id = $id; classification = 'NOT_COMPARABLE'; reason = 'missing required data' }
                continue
            }
            $report.comparable_ids++
            $mismatch = $false
            $reasons = @()
            if ([string]$lb.directory -ne [string]$ns.directory) { $mismatch = $true; $reasons += 'directory' }
            if (-not [string]::IsNullOrWhiteSpace([string]$lb.project) -and -not [string]::IsNullOrWhiteSpace([string]$ns.projectId)) {
                if ([string]$lb.project -ne [string]$ns.projectId) { $mismatch = $true; $reasons += 'project' }
            }
            $lt = ConvertTo-ShadowTimestampMs $lb.updated_at
            $nt = ConvertTo-ShadowTimestampMs $ns.updated
            if ($null -ne $lt -and $null -ne $nt) {
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
        foreach ($c in $report.classifications) {
            if ($c.classification -eq 'LOCAL_ONLY') {
                $c | Add-Member -NotePropertyName note -NotePropertyValue 'native sample may be truncated' -Force
            }
        }
    }

    $report.metrics = [ordered]@{
        local_candidates = $report.local_candidates
        real_local_bindings = $report.real_local_bindings
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