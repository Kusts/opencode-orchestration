function ConvertFrom-OrchestrationProviderFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Failure,
        [ValidateSet('pre_dispatch', 'post_dispatch', 'unknown')][string]$Stage = 'unknown'
    )

    $fields = @{}
    $textParts = New-Object 'System.Collections.Generic.List[string]'
    $walk = {
        param($value, [int]$depth)
        if ($null -eq $value -or $depth -gt 5) { return }
        if ($value -is [string]) {
            $s = $value
            if ($s.Length -gt 512) { $s = $s.Substring(0, 512) }
            if ($s.TrimStart().StartsWith('{')) {
                try { $parsed = ConvertFrom-Json -InputObject $s -ErrorAction Stop; & $walk $parsed ($depth + 1); return } catch {}
            }
            if ($textParts.Count -lt 8) { $textParts.Add($s) }
            return
        }
        $entries = @()
        if ($value -is [System.Collections.IDictionary]) {
            foreach ($key in $value.Keys) { $entries += ,@([string]$key, $value[$key]) }
        } elseif ($value -is [psobject]) {
            foreach ($property in $value.PSObject.Properties) { $entries += ,@([string]$property.Name, $property.Value) }
        }
        foreach ($entry in $entries) {
            $key = ([string]$entry[0]).ToLowerInvariant()
            $v = $entry[1]
            if ($key -in @('http_status','status','statuscode') -and -not $fields.ContainsKey('http_status')) { $fields.http_status = $v }
            elseif ($key -in @('code','error_code') -and -not $fields.ContainsKey('code')) {
                $fields.code = $v
                $numericCode = 0
                if (-not $fields.ContainsKey('http_status') -and [int]::TryParse([string]$v, [ref]$numericCode)) { $fields.http_status = $numericCode }
            }
            elseif ($key -in @('type','error_type') -and -not $fields.ContainsKey('error_type')) { $fields.error_type = $v }
            elseif ($key -eq 'provider' -and -not $fields.ContainsKey('provider')) { $fields.provider = $v }
            elseif ($key -eq 'model' -and -not $fields.ContainsKey('model')) { $fields.model = $v }
            elseif ($key -in @('attempt_id','attemptid') -and -not $fields.ContainsKey('attempt_id')) { $fields.attempt_id = $v }
            elseif ($key -eq 'stage' -and -not $fields.ContainsKey('stage')) { $fields.stage = $v }
            if ($key -in @('message','error','detail') -and $v -is [string] -and $textParts.Count -lt 8) {
                $s = [string]$v; if ($s.Length -gt 512) { $s = $s.Substring(0,512) }; $textParts.Add($s)
            } elseif ($v -is [System.Collections.IDictionary] -or $v -is [psobject] -and $v -isnot [string]) {
                & $walk $v ($depth + 1)
            }
        }
    }
    try { & $walk $Failure 0 } catch {}

    $status = $null
    if ($fields.ContainsKey('http_status')) {
        $n = 0
        if ([int]::TryParse([string]$fields.http_status, [ref]$n)) { $status = $n }
    }
    $code = $null; if ($fields.ContainsKey('code') -and $fields.code -is [string]) { $code = $fields.code }
    $type = $null; if ($fields.ContainsKey('error_type') -and $fields.error_type -is [string]) { $type = $fields.error_type }
    $provider = $null; if ($fields.ContainsKey('provider') -and $fields.provider -is [string]) { $provider = $fields.provider }
    $model = $null; if ($fields.ContainsKey('model') -and $fields.model -is [string]) { $model = $fields.model }
    $attempt = $null; if ($fields.ContainsKey('attempt_id') -and $fields.attempt_id -is [string]) { $attempt = $fields.attempt_id }
    $effectiveStage = $Stage
    if ($Stage -eq 'unknown' -and $fields.ContainsKey('stage') -and [string]$fields.stage -in @('pre_dispatch','post_dispatch','unknown')) { $effectiveStage = [string]$fields.stage }
    $text = ($textParts -join ' ')
    if ($text.Length -gt 512) { $text = $text.Substring(0,512) }
    $allText = (($code, $type, $text) -join ' ').ToLowerInvariant()
    $classification = 'NONE'; $source = 'none'
    $codeNorm = if ($code) { $code.ToLowerInvariant() } else { '' }
    $typeNorm = if ($type) { $type.ToLowerInvariant() } else { '' }
    $aliasText = ($codeNorm + ' ' + $typeNorm + ' ' + $text.ToLowerInvariant())
    $classifyCode = {
        param([string]$value)
        if ($value -match 'server_overloaded|service_unavailable|bad_gateway') { return 'PROVIDER_UNAVAILABLE' }
        if ($value -match 'rate_limit|too_many_requests|overloaded|slow_down') { return 'RATE_LIMIT' }
        if ($value -match 'quota_exceeded|usage_limit|reached your usage limit|resource_exhausted|resource exhausted') { return 'QUOTA_EXCEEDED' }
        if ($value -match 'model_unavailable|model_not_found|model_not_supported|model_decommissioned|no such model') { return 'MODEL_UNAVAILABLE' }
        if ($value -match 'internal_error|internal server error') { return 'PROVIDER_ERROR' }
        if ($value -match 'invalid api key|unauthorized|forbidden|permission denied|insufficient permissions') { return 'AUTH_OR_PERMISSION_ERROR' }
        if ($value -match 'context_length_exceeded|context too large|invalid_request|invalid input') { return 'REQUEST_INVALID' }
        if ($value -match 'timeout|timed out|etimedout|connection reset|econnreset|aborted|stream interrupted|unknown result') { return 'EXECUTION_UNKNOWN' }
        return 'NONE'
    }
    if ($null -ne $status) {
        $source = 'http_status'
        switch ($status) {
            429 { $classification = 'RATE_LIMIT' }
            529 { if ($aliasText -match 'overloaded') { $classification = 'RATE_LIMIT' } else { $classification = 'PROVIDER_UNAVAILABLE' } }
            502 { $classification = 'PROVIDER_UNAVAILABLE' }
            503 { $classification = 'PROVIDER_UNAVAILABLE' }
            504 { $classification = 'PROVIDER_UNAVAILABLE' }
            500 { $classification = 'PROVIDER_ERROR' }
            401 { $classification = 'AUTH_OR_PERMISSION_ERROR' }
            403 { $classification = 'AUTH_OR_PERMISSION_ERROR' }
            400 { $classification = 'REQUEST_INVALID' }
            413 { $classification = 'REQUEST_INVALID' }
            408 { $classification = 'EXECUTION_UNKNOWN' }
            409 { $classification = 'PROVIDER_ERROR' }
            default { $classification = & $classifyCode $aliasText; if ($classification -eq 'NONE') { $source = 'http_status' } }
        }
    } elseif ($code) {
        $classification = & $classifyCode $codeNorm
        $source = 'structured_code'
    }
    if ($classification -eq 'NONE' -and $type) {
        $classification = & $classifyCode $typeNorm
        if ($classification -ne 'NONE') { $source = 'error_type' }
    }
    if ($classification -eq 'NONE' -and $text) {
        $classification = & $classifyCode $text.ToLowerInvariant()
        if ($classification -ne 'NONE') { $source = 'alias' }
    }
    $availability = $classification -in @('RATE_LIMIT','QUOTA_EXCEEDED','MODEL_UNAVAILABLE','PROVIDER_UNAVAILABLE')
    $configuration = $classification -in @('AUTH_OR_PERMISSION_ERROR','REQUEST_INVALID')
    $reason = $classification.ToLowerInvariant()
    if ($reason.Length -gt 64) { $reason = $reason.Substring(0,64) }
    return [pscustomobject]@{
        Classification = $classification
        Availability = [bool]$availability
        Configuration = [bool]$configuration
        FallbackEligible = [bool]$availability
        Ambiguous = [bool]($classification -eq 'EXECUTION_UNKNOWN')
        RetrySafePreExecution = [bool]($availability -and $effectiveStage -eq 'pre_dispatch')
        Signals = [pscustomobject]@{ http_status = $status; code = $code; error_type = $type; provider = $provider; model = $model; stage = $effectiveStage; attempt_id = $attempt; source = $source }
        Reason = $reason
    }
}
