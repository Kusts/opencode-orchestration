<#!
.SYNOPSIS
    Cache-aware token/cost metrics from an OpenCode session observation.
.DESCRIPTION
    Pure parser: no network, no model call. Never invents zero for an
    unknown cost; missing or zero cost is reported as UNKNOWN with a source
    flag. PS 5.1 compatible, ASCII-only.
#>
function Get-OrchestrationCacheMetricValue {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    $p = $Node.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-OrchestrationCacheNumber {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        $n = [double]$Value
        if ($n -lt 0) { return $null }
        return $n
    }
    return $null
}

function Get-OrchestrationCacheMetrics {
    <#
    .SYNOPSIS
        Extracts input/output/reasoning/cache tokens and cost from a session.
    .PARAMETER Session
        Session info object or JSON string (with or without the `data` wrapper).
    .OUTPUTS
        @{ ok; prompt_tokens; input_tokens; output_tokens; reasoning_tokens;
           cache_read_tokens; cache_write_tokens; cache_read_ratio;
           cost; cost_source; error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [int]$MaxInputTokens = 0
    )
    try {
        $doc = $Session
        if ($Session -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$Session)) { return @{ ok = $false; error = 'CACHE_METRICS_INVALID' } }
            try { $doc = ([string]$Session | ConvertFrom-Json) } catch { return @{ ok = $false; error = 'CACHE_METRICS_INVALID' } }
        }
        if ($null -eq $doc) { return @{ ok = $false; error = 'CACHE_METRICS_INVALID' } }

        $data = Get-OrchestrationCacheMetricValue -Node $doc -Name 'data'
        if ($null -ne $data) { $doc = $data }
        $tokens = Get-OrchestrationCacheMetricValue -Node $doc -Name 'tokens'
        if ($null -eq $tokens) { return @{ ok = $false; error = 'CACHE_METRICS_TOKENS_MISSING' } }

        $inputRaw = ConvertTo-OrchestrationCacheNumber (Get-OrchestrationCacheMetricValue -Node $tokens -Name 'input')
        $outputRaw = ConvertTo-OrchestrationCacheNumber (Get-OrchestrationCacheMetricValue -Node $tokens -Name 'output')
        $reasoningRaw = ConvertTo-OrchestrationCacheNumber (Get-OrchestrationCacheMetricValue -Node $tokens -Name 'reasoning')
        $cacheNode = Get-OrchestrationCacheMetricValue -Node $tokens -Name 'cache'
        $cacheReadRaw = $null
        $cacheWriteRaw = $null
        if ($null -ne $cacheNode) {
            $cacheReadRaw = ConvertTo-OrchestrationCacheNumber (Get-OrchestrationCacheMetricValue -Node $cacheNode -Name 'read')
            $cacheWriteRaw = ConvertTo-OrchestrationCacheNumber (Get-OrchestrationCacheMetricValue -Node $cacheNode -Name 'write')
        }

        if ($null -eq $inputRaw) { return @{ ok = $false; error = 'CACHE_METRICS_INPUT_MISSING' } }
        if ($MaxInputTokens -gt 0 -and $inputRaw -gt $MaxInputTokens) {
            return @{ ok = $false; error = 'CACHE_METRICS_INPUT_OUT_OF_RANGE' }
        }

        $cacheRead = if ($null -eq $cacheReadRaw) { 'UNKNOWN' } else { [int64]$cacheReadRaw }
        $cacheWrite = if ($null -eq $cacheWriteRaw) { 'UNKNOWN' } else { [int64]$cacheWriteRaw }
        $prompt = [int64]$inputRaw
        $ratio = 'UNKNOWN'
        if (($cacheReadRaw -ne $null) -and ($prompt + [int64]$cacheReadRaw -gt 0)) {
            $ratio = [Math]::Round(([double]$cacheReadRaw / [double]($prompt + [int64]$cacheReadRaw)), 6)
        }

        $costRaw = ConvertTo-OrchestrationCacheNumber (Get-OrchestrationCacheMetricValue -Node $doc -Name 'cost')
        $cost = 'UNKNOWN'
        $costSource = 'unknown'
        if (($null -ne $costRaw) -and ($costRaw -gt 0)) { $cost = $costRaw; $costSource = 'reported' }

        return @{
            ok = $true
            error = ''
            prompt_tokens = $prompt
            input_tokens = [int64]$inputRaw
            output_tokens = if ($null -eq $outputRaw) { 'UNKNOWN' } else { [int64]$outputRaw }
            reasoning_tokens = if ($null -eq $reasoningRaw) { 'UNKNOWN' } else { [int64]$reasoningRaw }
            cache_read_tokens = $cacheRead
            cache_write_tokens = $cacheWrite
            cache_read_ratio = $ratio
            cost = $cost
            cost_source = $costSource
        }
    }
    catch { return @{ ok = $false; error = 'CACHE_METRICS_INVALID' } }
}
