<#!
.SYNOPSIS
    Dev telemetry record CLI: append one review_outcome event.
.DESCRIPTION
    Appends a single review_outcome event to cache/v3/telemetry/dev via
    scripts/v3/lib/DevTelemetry.ps1. Prints exactly one line on stdout.
    Exit 0 recorded; exit 1 write failure; exit 2 invalid argument.
    PowerShell 5.1 compatible. ASCII-only on purpose.
#>
[CmdletBinding()]
param(
    [string]$Verdict = '',
    [string]$Detail = '',
    [string]$Source = 'planner',
    [string]$Severity = '',
    [string]$RepoRoot = '',
    [string]$Now = ''
)

$ErrorActionPreference = 'Stop'

function Write-RecordFail([int]$Code) {
    Write-Output 'dev-telemetry: failed to record review_outcome'
    exit $Code
}

try {
    if (($Verdict -cne 'APPROVED') -and ($Verdict -cne 'CHANGES_REQUIRED')) {
        Write-RecordFail 2
    }
    $severityTrimmed = ([string]$Severity).Trim().ToUpperInvariant()
    if (-not [string]::IsNullOrWhiteSpace($severityTrimmed) -and @('NONE','LOW','MEDIUM','HIGH','CRITICAL') -cnotcontains $severityTrimmed) { Write-RecordFail 2 }
    if (([string]$Source).Contains("`n") -or ([string]$Source).Contains("`r")) {
        Write-RecordFail 2
    }
    $srcTrimmed = ([string]$Source).Trim()
    if ([string]::IsNullOrWhiteSpace($srcTrimmed) -or ($srcTrimmed -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z')) {
        Write-RecordFail 2
    }
    $detTrimmed = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Detail)) {
        $detTrimmed = ([string]$Detail).Trim()
        if (($detTrimmed -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z')) {
            Write-RecordFail 2
        }
    }
}
catch {
    Write-Output 'dev-telemetry: failed to record review_outcome'
    exit 2
}

$libPath = Join-Path $PSScriptRoot 'v3\lib\DevTelemetry.ps1'
try {
    . $libPath
}
catch {
    Write-Output 'dev-telemetry: failed to record review_outcome'
    exit 1
}

$ok = $false
try {
    $ok = Write-DevTelemetryEvent -Kind 'review_outcome' -Source $srcTrimmed -Verdict $Verdict -Severity $severityTrimmed -Detail $detTrimmed -RepoRoot $RepoRoot -Timestamp $Now
}
catch {
    $ok = $false
}

if ($ok -eq $true) {
    $line = 'dev-telemetry: recorded review_outcome=' + $Verdict + ' source=' + $srcTrimmed
    if (-not [string]::IsNullOrWhiteSpace($severityTrimmed)) { $line += ' severity=' + $severityTrimmed }
    Write-Output $line
    exit 0
}

Write-Output 'dev-telemetry: failed to record review_outcome'
exit 1
