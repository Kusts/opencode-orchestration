<#
.SYNOPSIS
    Process-level tests for observed cache metrics CLI.
    PowerShell 5.1/7 compatible, ASCII-only, temporary files only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:CliPath = Join-Path $PSScriptRoot 'cache-metrics.ps1'
$script:HostExe = ''
try { $script:HostExe = [string](Get-Process -Id $PID).Path } catch { }
if ([string]::IsNullOrWhiteSpace($script:HostExe)) {
    if ($PSVersionTable.PSEdition -eq 'Core') { $script:HostExe = Join-Path $PSHOME 'pwsh.exe' }
    else { $script:HostExe = Join-Path $PSHOME 'powershell.exe' }
}

function Assert-CacheMetrics {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else {
        Write-Host ('[FAIL] ' + $Name + $(if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' -- ' + $Detail }))
        $script:Failed++
    }
}

function Invoke-CacheMetricsCli {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $quoted = @()
    foreach ($arg in @($CliArgs)) { $quoted += ('"' + ([string]$arg).Replace('"', '\"') + '"') }
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:CliPath + '" ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($stdout)) { $json = ConvertFrom-Json -InputObject $stdout } } catch { }
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout.Trim(); Stderr = $stderr.Trim(); Json = $json }
}

if (-not (Test-Path -LiteralPath $script:HostExe -PathType Leaf)) {
    Assert-CacheMetrics $false 'CLI host executable available' $script:HostExe
}
else {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('cache-metrics-' + [Guid]::NewGuid().ToString('N'))
    $noCostFile = Join-Path $root 'no-cost.json'
    $invalidFile = Join-Path $root 'invalid.json'
    try {
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText($noCostFile, '{"tokens":{"input":10,"output":2,"cache":{"read":5,"write":1}}}', [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($invalidFile, '{not-json', [Text.Encoding]::ASCII)
        $noCost = Invoke-CacheMetricsCli @('-SessionFile', $noCostFile)
        Assert-CacheMetrics (($noCost.ExitCode -eq 0) -and [bool]$noCost.Json.ok -and ([string]$noCost.Json.cost -ceq 'UNKNOWN') -and ([string]$noCost.Json.cost_source -ceq 'unknown')) 'missing cost stays UNKNOWN, never zero' ($noCost.Stdout + ' ' + $noCost.Stderr)
        $bad = Invoke-CacheMetricsCli @('-SessionFile', $invalidFile)
        Assert-CacheMetrics (($bad.ExitCode -eq 2) -and (-not [bool]$bad.Json.ok)) 'invalid JSON exits 2' ($bad.Stdout + ' ' + $bad.Stderr)

        $step1Path = Join-Path (Split-Path -Parent $PSScriptRoot) '..\evidence\evolution-2026-11-10\p0-autonomy\session-resume\step1.json'
        $step2Path = Join-Path (Split-Path -Parent $PSScriptRoot) '..\evidence\evolution-2026-11-10\p0-autonomy\session-resume\step2.json'
        $step1Path = [IO.Path]::GetFullPath($step1Path)
        $step2Path = [IO.Path]::GetFullPath($step2Path)
        if ((Test-Path -LiteralPath $step1Path -PathType Leaf) -and (Test-Path -LiteralPath $step2Path -PathType Leaf)) {
            $step1 = Invoke-CacheMetricsCli @('-SessionFile', $step1Path)
            $step2 = Invoke-CacheMetricsCli @('-SessionFile', $step2Path)
            Assert-CacheMetrics (($step1.ExitCode -eq 0) -and [bool]$step1.Json.ok -and ([long]$step1.Json.input_tokens -eq 47313) -and ([long]$step1.Json.cache_read_tokens -eq 512) -and ([Math]::Abs([double]$step1.Json.cache_read_ratio - 0.010706) -lt 0.000001)) 'P0.6 step1 metrics read from observed sample' ($step1.Stdout + ' ' + $step1.Stderr)
            Assert-CacheMetrics (($step2.ExitCode -eq 0) -and [bool]$step2.Json.ok -and ([long]$step2.Json.input_tokens -eq 108) -and ([long]$step2.Json.cache_read_tokens -eq 47744) -and ([Math]::Abs([double]$step2.Json.cache_read_ratio - 0.997743) -lt 0.000001)) 'P0.6 step2 metrics read from observed sample' ($step2.Stdout + ' ' + $step2.Stderr)
        }
        else { Assert-CacheMetrics $false 'P0.6 observed sample files available' ($step1Path + ' ; ' + $step2Path) }
    }
    finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } }
}

Write-Host ''
Write-Host ('CACHE-METRICS: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
if ($script:Failed -gt 0) { exit 1 }
exit 0
