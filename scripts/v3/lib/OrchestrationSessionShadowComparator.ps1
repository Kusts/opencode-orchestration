<#
.SYNOPSIS
    Pure read-only comparator between native OpenCode V2 sessions and local catalog bindings.
.DESCRIPTION
    Distinguishes session_id, directory, project_name (local) and project_id (opaque runtime).
    Project name vs opaque id is NOT treated as FIELD_MISMATCH; marked as not comparable
    for that dimension only (project_schema_incompatible).
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
        identity_matches = 0
        directory_matches = 0
        project_matches = 0
        full_matches = 0
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

    # truncation based on raw count before filters
    if ($NativeLimit -gt 0 -and $nativeRaw.Count -ge $NativeLimit) {
        $report.truncated = $true
    }

    if ($malformedNative) {
        $report.not_comparable = @($LocalBindings).Count
        $report.status = 'not_comparable'
        $report.metrics.note = 'native result malformed'
        return [pscustomobject]$report
    }

    # QUERY_ERROR branch
    if ($NativeResult -is [pscustomobject] -and $NativeResult.PSObject.Properties['ok'] -and -not $NativeResult.ok) {
        $report.query_error = $true
        $report.status = 'query_error'
        $locals = @($LocalBindings)
        if (-not [string]::IsNullOrWhiteSpace($ProjectFilter)) {
            $locals = @($locals | Where-Object { [string]$_.directory -eq $ProjectFilter -or [string]$_.project -eq $ProjectFilter })
        }
        $report.local_candidates = @($LocalBindings).Count
        $report.real_local_bindings = @($locals | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.session_id) }).Count
        $report.local_count = $locals.Count
        foreach ($lb in $locals) {
            $report.classifications += [pscustomobject]@{ id = [string]$lb.session_id; classification = 'QUERY_ERROR'; reason = 'native query failed' }
        }
        return [pscustomobject]$report
    }

    # Apply ProjectFilter by directory (not by opaque project id)
    $nativeSessions = $nativeRaw
    $locals = @($LocalBindings)
    if (-not [string]::IsNullOrWhiteSpace($ProjectFilter)) {
        $nativeSessions = @($nativeSessions | Where-Object { [string]$_.directory -eq $ProjectFilter })
        $locals = @($locals | Where-Object { [string]$_.directory -eq $ProjectFilter -or [string]$_.project -eq $ProjectFilter })
    }

    $report.local_candidates = @($LocalBindings).Count
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
            $ns = $nativeMap[$id]
            $lb = $localMap[$id]
            # NOT_COMPARABLE if missing required data
            if ([string]::IsNullOrWhiteSpace([string]$id) -or [string]::IsNullOrWhiteSpace([string]$lb.directory) -or [string]::IsNullOrWhiteSpace([string]$ns.directory)) {
                $report.not_comparable++
                $report.classifications += [pscustomobject]@{ id = $id; classification = 'NOT_COMPARABLE'; reason = 'missing required data' }
                continue
            }
            $report.comparable_ids++
            $report.identity_matches++

            # directory equivalence
            $dirMatch = ([string]$lb.directory -eq [string]$ns.directory)
            if ($dirMatch) { $report.directory_matches++ }

            # project equivalence: compare only if both use same scheme
            # Local uses friendly name, native uses opaque id -> not comparable dimension
            $projectComparable = $false
            $projectMatch = $false
            if (-not [string]::IsNullOrWhiteSpace([string]$lb.project) -and -not [string]::IsNullOrWhiteSpace([string]$ns.projectId)) {
                # Only comparable if they look like the same scheme (both opaque hashes or both names)
                $localIsHash = [string]$lb.project -match '^[a-f0-9]{20,}$'
                $nativeIsHash = [string]$ns.projectId -match '^[a-f0-9]{20,}$'
                if ($localIsHash -eq $nativeIsHash) {
                    $projectComparable = $true
                    if ([string]$lb.project -eq [string]$ns.projectId) { $projectMatch = $true }
                }
            }
            if ($projectComparable -and $projectMatch) { $report.project_matches++ }

            # field mismatch: only directory and timestamp (project schema handled separately)
            $mismatch = $false
            $reasons = @()
            if (-not $dirMatch) { $mismatch = $true; $reasons += 'directory' }
            $lt = ConvertTo-ShadowTimestampMs $lb.updated_at
            $nt = ConvertTo-ShadowTimestampMs $ns.updated
            if ($null -ne $lt -and $null -ne $nt) {
                if ([Math]::Abs($lt - $nt) -gt 5000) { $mismatch = $true; $reasons += 'timestamp' }
            }
            # project schema incompatibility is reported but not a mismatch
            $projectNote = ''
            if (-not $projectComparable) { $projectNote = 'project_schema_incompatible' }

            if ($mismatch) {
                $report.field_mismatches++
                $report.classifications += [pscustomobject]@{ id = $id; classification = 'FIELD_MISMATCH'; fields = ($reasons -join ','); project_note = $projectNote }
            } else {
                $report.matches++
                if ($projectComparable -and $projectMatch) { $report.full_matches++ }
                $report.classifications += [pscustomobject]@{ id = $id; classification = 'MATCH'; fields = ''; project_note = $projectNote }
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
        identity_matches = $report.identity_matches
        directory_matches = $report.directory_matches
        project_matches = $report.project_matches
        full_matches = $report.full_matches
        matches = $report.matches
        field_mismatches = $report.field_mismatches
        native_only = $report.native_only
        local_only = $report.local_only
        truncated = $report.truncated
    }
    return [pscustomobject]$report
}