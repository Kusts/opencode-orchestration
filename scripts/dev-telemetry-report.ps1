<#!
.SYNOPSIS
    Dev telemetry report CLI: aggregate local JSONL into JSON+MD snapshots.
.DESCRIPTION
    Reads cache/v3/telemetry/dev via lib/DevTelemetry.ps1 and writes
    cache/v3/dev-metrics/latest.json + latest.md; with -Publish also writes
    evidence/dev-telemetry/latest.json + latest.md + history/YYYY-Www.json.
    Prints exactly one line: dev-telemetry: events=N suites=R pass=P fail=F publish=on|off
    Exit 0; exit 2 on invalid argument. PowerShell 5.1. ASCII-only.
#>
[CmdletBinding()]
param(
    [int]$WindowDays = 30,
    [switch]$Publish,
    [string]$RepoRoot = '',
    [string]$Now = ''
)

$ErrorActionPreference = 'Stop'

try {
    if ($WindowDays -lt 1 -or $WindowDays -gt 3650) {
        [Console]::Error.WriteLine('dev-telemetry: invalid -WindowDays (1..3650).')
        exit 2
    }
    if (-not [string]::IsNullOrWhiteSpace($Now)) {
        $probe = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($Now, [ref]$probe)) {
            [Console]::Error.WriteLine('dev-telemetry: invalid -Now (unparseable timestamp).')
            exit 2
        }
    }
}
catch {
    [Console]::Error.WriteLine('dev-telemetry: invalid argument.')
    exit 2
}

$repo = $RepoRoot
if ([string]::IsNullOrWhiteSpace($repo)) {
    $here = $PSScriptRoot
    $repo = (Resolve-Path -LiteralPath (Join-Path $here '..')).Path
}

$libPath = Join-Path $repo 'scripts\v3\lib\DevTelemetry.ps1'
try {
    . $libPath
}
catch {
    [Console]::Error.WriteLine('dev-telemetry: lib load failed.')
    exit 2
}

$snap = $null
try {
    if ($Publish) {
        $snap = Export-DevTelemetrySnapshot -RepoRoot $repo -WindowDays $WindowDays -Publish -Now $Now
    }
    else {
        $snap = Export-DevTelemetrySnapshot -RepoRoot $repo -WindowDays $WindowDays -Now $Now
    }
}
catch {
    $snap = $null
}

$n = 0
$r = 0
$p = 0
$f = 0
try {
    if ($null -ne $snap) {
        try { $n = [int]$snap.raw.events } catch { $n = 0 }
        try { $r = @($snap.suites).Count } catch { $r = 0 }
        try { $p = [int]$snap.totals.pass } catch { $p = 0 }
        try { $f = [int]$snap.totals.fail } catch { $f = 0 }
    }
}
catch { }

$pubFlag = 'off'
if ($Publish) { $pubFlag = 'on' }
Write-Output ('dev-telemetry: events=' + $n + ' suites=' + $r + ' pass=' + $p + ' fail=' + $f + ' publish=' + $pubFlag)
exit 0
