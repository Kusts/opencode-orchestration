<#
.SYNOPSIS
    CLI for observed session token, cache, and cost metrics.
.DESCRIPTION
    Thin wrapper over Get-OrchestrationCacheMetrics. No inferred costs or network.
    PowerShell 5.1/7 compatible, ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$SessionFile = '',
    [AllowEmptyString()][string]$SessionJson = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationCacheMetrics.ps1')

function Write-CacheMetricsJson {
    param($Value)
    Write-Output (ConvertTo-Json -InputObject $Value -Depth 8 -Compress)
}

function Stop-CacheMetrics {
    param([string]$ErrorCode, [int]$ExitCode)
    Write-CacheMetricsJson ([ordered]@{ ok = $false; error = $ErrorCode })
    exit $ExitCode
}

$hasFile = $PSBoundParameters.ContainsKey('SessionFile') -and -not [string]::IsNullOrWhiteSpace($SessionFile)
$hasJson = $PSBoundParameters.ContainsKey('SessionJson')
if ($hasFile -eq $hasJson) { Stop-CacheMetrics 'USAGE_REQUIRES_SESSIONFILE_OR_SESSIONJSON' 2 }

if ($hasFile) {
    if (-not (Test-Path -LiteralPath $SessionFile -PathType Leaf)) { Stop-CacheMetrics 'SESSION_FILE_NOT_FOUND' 2 }
    try { $sessionText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SessionFile).Path, [Text.Encoding]::UTF8) }
    catch { Stop-CacheMetrics 'SESSION_FILE_READ_FAILED' 1 }
    $metrics = Get-OrchestrationCacheMetrics -Session $sessionText
    if (-not [bool]$metrics.ok) {
        $metrics = $null
        foreach ($line in @($sessionText -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $entry = ConvertFrom-Json -InputObject $line } catch { continue }
            $candidate = $entry
            if ($null -ne $entry.PSObject.Properties['part']) { $candidate = $entry.part }
            $parsed = Get-OrchestrationCacheMetrics -Session $candidate
            if ([bool]$parsed.ok) { $metrics = $parsed }
        }
        if ($null -eq $metrics) { Stop-CacheMetrics 'CACHE_METRICS_INVALID' 2 }
    }
}
else {
    $metrics = Get-OrchestrationCacheMetrics -Session $SessionJson
    if (-not [bool]$metrics.ok) { Stop-CacheMetrics ([string]$metrics.error) 2 }
}

Write-CacheMetricsJson $metrics
exit 0
