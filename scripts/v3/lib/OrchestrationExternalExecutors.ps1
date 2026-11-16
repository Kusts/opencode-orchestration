[CmdletBinding()]
param()

function Get-OcExternalExecutors {
    $run = { param($Intent, $Evidence) return @{ status='UNKNOWN' } }
    return @{ 'telegran.fetch-one-message'=$run; 'telegran.learn-one'=$run }
}

function Invoke-OcExternalActionCli {
    [CmdletBinding()]
    param(
        [string]$ExecutorId, [string]$TaskId, [string]$Request,
        [string]$RepoRoot, [switch]$DryRun
    )
    . (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
    $registryPath = Join-Path $RepoRoot 'source/registry/external-executors.json'
    $grantsPath = Join-Path $RepoRoot 'source/registry/execution-grants.json'
    $validation = Test-OcExternalActionRequest -ExecutorId $ExecutorId -TaskId $TaskId -RequestJson $Request -RegistryPath $registryPath -GrantsPath $grantsPath
    if (-not $validation.valid) {
        $reason = if ($validation.error -eq 'INVALID_TASK_ID') { 'INVALID_TASK_ID' } else { $validation.error }
        return @{ outcome='INVALID_REQUEST';reasons=@($reason);executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$null;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun }
    }
    if ($DryRun) {
        return @{ outcome='WAIT';reasons=@('DRY_RUN_VALIDATED_NO_EFFECT');executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$null;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=$true }
    }
    return @{ outcome='NEEDS_USER_AUTHORITY';reasons=@('EFFECTIVE_GRANT_SOURCE_UNAVAILABLE');executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$null;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=$false }
}

function Test-OcExternalActionRequest {
    [CmdletBinding()]
    param([string]$ExecutorId,[string]$TaskId,[string]$RequestJson,[string]$RegistryPath,[string]$GrantsPath)
    . (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
    . (Join-Path $PSScriptRoot 'OrchestrationExternalExecutorRegistry.ps1')
    if (-not (Test-TaskKernelId -TaskId $TaskId)) { return @{valid=$false;error='INVALID_TASK_ID';payload=$null} }
    if ($RequestJson.Length -gt 8192) { return @{valid=$false;error='REQUEST_TOO_LARGE';payload=$null} }
    if ([string]::IsNullOrWhiteSpace($RequestJson) -or $RequestJson.TrimStart()[0] -ne '{') {
        return @{valid=$false;error='REQUEST_OBJECT_REQUIRED';payload=$null}
    }
    try {
        $impl = Get-OcExternalExecutors
        try { $registry = Import-OcExternalExecutorRegistry -Path $RegistryPath -GrantsPath $GrantsPath -Implementations $impl }
        catch { throw 'REGISTRY_INVALID' }
        $entry = @($registry.executors | Where-Object { $_.id -ceq $ExecutorId })
        if ($entry.Count -ne 1) { throw 'UNKNOWN_EXECUTOR' }
        $keyIssue = Get-OcJsonKeyIssue $RequestJson
        # Case-fold variants are rejected distinctly even where PS5 ConvertFrom-Json
        # reports them as duplicate properties. All other syntax still goes through
        # the platform parser before a payload is accepted.
        try { $req = ConvertFrom-Json -InputObject $RequestJson -ErrorAction Stop }
        catch {
            if ($keyIssue -eq 'UNKNOWN_REQUEST_KEY') { throw 'UNKNOWN_REQUEST_KEY' }
            throw 'MALFORMED_REQUEST_JSON'
        }
        if ($keyIssue -eq 'MALFORMED_REQUEST_JSON') { throw 'MALFORMED_REQUEST_JSON' }
        if ($keyIssue -eq 'DUPLICATE_REQUEST_KEY') { throw 'DUPLICATE_REQUEST_KEY' }
        if ($keyIssue -eq 'UNKNOWN_REQUEST_KEY') { throw 'UNKNOWN_REQUEST_KEY' }
        if ($null -eq $req -or $req -isnot [System.Management.Automation.PSCustomObject]) { throw 'REQUEST_OBJECT_REQUIRED' }
        $schemaKeys = @($entry[0].request_schema.PSObject.Properties.Name)
        $requestKeys = @($req.PSObject.Properties.Name)
        foreach ($k in $requestKeys) { if ($schemaKeys -cnotcontains $k) { throw 'UNKNOWN_REQUEST_KEY' } }
        foreach ($k in $schemaKeys) {
            if ($requestKeys -cnotcontains $k) { throw 'MISSING_REQUEST_KEY' }
            $v = $req.PSObject.Properties[$k].Value; $s = $entry[0].request_schema.PSObject.Properties[$k].Value
            if ($s.type -ceq 'enum' -and ($v -isnot [string] -or $v -cnotin @($s.values))) { throw 'INVALID_ENUM' }
            if ($s.type -ceq 'int' -and (-not (Test-OcIntegral $v) -or $v -lt $s.min -or $v -gt $s.max)) { throw 'INVALID_INT' }
            if ($s.type -ceq 'string' -and ($v -isnot [string] -or $v.Length -gt $s.max_length -or $v -cnotmatch ('\A(?:' + $s.regex + ')\z'))) { throw 'INVALID_STRING' }
        }
        return @{valid=$true;error=$null;payload=$req}
    } catch {
        $code = [string]$_.Exception.Message
        $allowed = @('UNKNOWN_EXECUTOR','DUPLICATE_REQUEST_KEY','REQUEST_OBJECT_REQUIRED','MALFORMED_REQUEST_JSON','UNKNOWN_REQUEST_KEY','MISSING_REQUEST_KEY','INVALID_ENUM','INVALID_INT','INVALID_STRING','REGISTRY_INVALID')
        if ($code -notin $allowed) { $code = 'REGISTRY_OR_INTERNAL_ERROR' }
        return @{valid=$false;error=$code;payload=$null}
    }
}

function Get-OcJsonKeyIssue {
    param([string]$Json)
    $objects = New-Object 'System.Collections.Generic.List[object]'
    $bracketDepth = 0; $inString = $false; $escaped = $false; $start = -1; $stringIsKey = $false
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $ch = $Json[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($ch -eq '\') { $escaped = $true; continue }
            if ($ch -eq '"') {
                $inString = $false
                if ($stringIsKey) {
                    $next = $i + 1
                    while ($next -lt $Json.Length -and [char]::IsWhiteSpace($Json[$next])) { $next++ }
                    if ($next -lt $Json.Length -and $Json[$next] -eq ':') {
                        $token = $Json.Substring($start,$i-$start+1)
                        try { $key = [string](ConvertFrom-Json -InputObject $token -ErrorAction Stop) } catch { return 'MALFORMED_REQUEST_JSON' }
                        $frame = $objects[$objects.Count - 1]
                        if (-not $frame.exact.Add($key)) { return 'DUPLICATE_REQUEST_KEY' }
                        if (-not $frame.folded.Add($key)) { return 'UNKNOWN_REQUEST_KEY' }
                        $frame.state = 'colon'
                    } else { return 'MALFORMED_REQUEST_JSON' }
                }
                $stringIsKey = $false
            }
            continue
        }
        if ($ch -eq '/') { return 'MALFORMED_REQUEST_JSON' }
        if ($ch -eq "'") { return 'MALFORMED_REQUEST_JSON' }
        $frame = $null
        if ($objects.Count -gt 0 -and $bracketDepth -eq $objects[$objects.Count - 1].arrayDepth) {
            $frame = $objects[$objects.Count - 1]
            if ([char]::IsWhiteSpace($ch)) { continue }
            if ($frame.state -eq 'keyOrEnd' -or $frame.state -eq 'keyOnly') {
                if ($ch -eq '"') { $stringIsKey = $true }
                elseif ($ch -eq '}' -and $frame.state -eq 'keyOrEnd') { }
                else { return 'MALFORMED_REQUEST_JSON' }
            } elseif ($frame.state -eq 'colon') {
                if ($ch -ne ':') { return 'MALFORMED_REQUEST_JSON' }
                $frame.state = 'value'
                continue
            } elseif ($frame.state -eq 'value') {
                if ($ch -eq ',') { $frame.state = 'keyOnly'; continue }
                if ($ch -eq '}') { $objects.RemoveAt($objects.Count - 1); continue }
            } elseif ($frame.state -eq 'commaOrEnd') {
                if ($ch -eq ',') { $frame.state = 'keyOnly'; continue }
                if ($ch -eq '}') { $objects.RemoveAt($objects.Count - 1); continue }
                return 'MALFORMED_REQUEST_JSON'
            }
        }
        switch -CaseSensitive ([string]$ch) {
            '"' { $inString = $true; $start = $i }
            '{' {
                $frame = [pscustomobject]@{
                    arrayDepth = $bracketDepth
                    exact = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
                    folded = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
                    state = 'keyOrEnd'
                }
                $objects.Add($frame)
            }
            '}' {
                if ($objects.Count -gt 0 -and $frame -and $frame.state -eq 'keyOrEnd') { $objects.RemoveAt($objects.Count - 1) }
                elseif ($objects.Count -gt 0 -and $frame) { return 'MALFORMED_REQUEST_JSON' }
            }
            '[' { $bracketDepth++ }
            ']' {
                $bracketDepth--
                if ($objects.Count -gt 0 -and $bracketDepth -eq $objects[$objects.Count - 1].arrayDepth -and $objects[$objects.Count - 1].state -eq 'value') {
                    $objects[$objects.Count - 1].state = 'commaOrEnd'
                }
            }
        }
    }
    if ($inString) { return 'MALFORMED_REQUEST_JSON' }
    return $null
}
