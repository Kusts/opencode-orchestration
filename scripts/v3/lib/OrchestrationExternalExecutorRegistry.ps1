[CmdletBinding()]
param()

function Test-OcIntegral {
    param($Value)
    return $null -ne $Value -and (
        $Value -is [System.SByte] -or $Value -is [System.Byte] -or
        $Value -is [System.Int16] -or $Value -is [System.UInt16] -or
        $Value -is [System.Int32] -or $Value -is [System.UInt32] -or
        $Value -is [System.Int64] -or $Value -is [System.UInt64]
    )
}

function Import-OcExternalExecutorRegistry {
    param([string]$Path, [string]$GrantsPath, $Implementations)
    $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $grantDoc = Get-Content -Raw -LiteralPath $GrantsPath | ConvertFrom-Json
    if (-not (Test-OcIntegral $doc.schema_version) -or $doc.schema_version -ne 1) { throw 'Invalid schema_version' }
    foreach ($k in $doc.PSObject.Properties.Name) { if ($k -cnotin @('schema_version','executors')) { throw "Unknown registry property: $k" } }
    $allowed = @($grantDoc.grants)
    $ids = @{}
    $executorKeys = @('id','required_grants','risk','request_schema','target_template','fixed','timeout_seconds','idempotent')
    foreach ($e in @($doc.executors)) {
        foreach ($k in $e.PSObject.Properties.Name) { if ($k -cnotin $executorKeys) { throw "Unknown executor property: $k" } }
        foreach ($k in $executorKeys) { if ($k -cnotin $e.PSObject.Properties.Name) { throw "Missing executor property: $k" } }
        $id = [string]$e.id
        if ($id -notmatch '^[a-z0-9][a-z0-9.-]*$' -or $ids.ContainsKey($id)) { throw 'Invalid or duplicate executor id' }
        $ids[$id] = $true
        if (-not $Implementations.ContainsKey($id)) { throw "Executor implementation missing: $id" }
        if ([string]$e.risk -notin @('low','medium','high','critical')) { throw "Invalid risk: $id" }
        if (-not (Test-OcIntegral $e.timeout_seconds) -or $e.timeout_seconds -lt 1 -or $e.timeout_seconds -gt 86400) { throw "Invalid timeout: $id" }
        if (@($e.required_grants).Count -eq 0) { throw "required_grants is empty: $id" }
        foreach ($g in $e.required_grants) { if ($g -cnotin $allowed) { throw "Required grant unavailable: $g" } }
        $repo = [string]$e.fixed.repo
        if (-not [IO.Path]::IsPathRooted($repo) -or $repo.Contains('..') -or -not (Test-Path -LiteralPath $repo -PathType Container)) { throw "Invalid fixed repo: $id" }
        foreach ($k in $e.fixed.PSObject.Properties.Name) { if ($k -cne 'repo') { throw "Unknown fixed property: $k" } }
        $schemaNames = @($e.request_schema.PSObject.Properties.Name)
        foreach ($name in $schemaNames) {
            $s = $e.request_schema.$name
            if ($s.type -ceq 'enum') {
                foreach ($p in $s.PSObject.Properties.Name) { if ($p -cnotin @('type','values')) { throw "Unknown enum schema property: $p" } }
                if (@($s.values).Count -eq 0) { throw 'Empty enum' }
            } elseif ($s.type -ceq 'int') {
                foreach ($p in $s.PSObject.Properties.Name) { if ($p -cnotin @('type','min','max')) { throw "Unknown int schema property: $p" } }
                if (-not (Test-OcIntegral $s.min) -or -not (Test-OcIntegral $s.max) -or $s.min -gt $s.max) { throw 'Invalid int bounds' }
            } elseif ($s.type -ceq 'string') {
                foreach ($p in $s.PSObject.Properties.Name) { if ($p -cnotin @('type','regex','max_length')) { throw "Unknown string schema property: $p" } }
                if ([string]$s.regex -notmatch '^\^.*\$$' -or -not (Test-OcIntegral $s.max_length) -or $s.max_length -lt 1) { throw 'Invalid string schema' }
            } else { throw "Unsupported request schema type: $($s.type)" }
        }
        $placeholders = [regex]::Matches([string]$e.target_template, '\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value }
        foreach ($ph in $placeholders) { if ($ph -cnotin $schemaNames) { throw "Undeclared target placeholder: $ph" } }
        if ([string]$e.target_template -match '\{[^}]*$|^[^{}]*\}') { throw 'Malformed target template' }
    }
    return $doc
}
