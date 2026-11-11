<#
.SYNOPSIS
    Read-only CLI for deterministic localized repair decisions.
.DESCRIPTION
    Validates input, calls Resolve-OrchestrationLocalizedRepair, and prints
    the decision as JSON. It never dispatches work or performs IO beyond streams.
    PowerShell 5.1 and PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$Severity = 'medium',
    [string]$ChangedFiles = '1',
    [string]$ScopeOverlap = 'true',
    [string]$ExternalEffectsAmbiguous = 'false',
    [string]$EvidenceCurrent = 'true',
    [string]$Attempts = '0',
    [string]$FailureClass = 'localized'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationLocalizedRepair.ps1')

function Write-RepairCliError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Convert-RepairCliInteger {
    param([string]$Name, [string]$Value, [int]$Minimum, [int]$Maximum)
    $parsed = 0
    $valid = [int]::TryParse(([string]$Value).Trim(), [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
    if (-not $valid -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Write-RepairCliError ("-" + $Name + " must be an integer from " + $Minimum + " to " + $Maximum + ".")
        exit 2
    }
    return $parsed
}

function Convert-RepairCliBoolean {
    param([string]$Name, [string]$Value)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -ceq 'true') { return $true }
    if ($text -ceq 'false') { return $false }
    Write-RepairCliError ("-" + $Name + " must be true or false.")
    exit 2
}

$severityValue = ([string]$Severity).Trim().ToLowerInvariant()
if (@('low', 'medium', 'high', 'critical') -cnotcontains $severityValue) {
    Write-RepairCliError '-Severity must be low, medium, high, or critical.'
    exit 2
}
$failureClassValue = ([string]$FailureClass).Trim().ToLowerInvariant()
if (@('localized', 'unknown', 'structural') -cnotcontains $failureClassValue) {
    Write-RepairCliError '-FailureClass must be localized, unknown, or structural.'
    exit 2
}
$changedFilesValue = Convert-RepairCliInteger -Name 'ChangedFiles' -Value $ChangedFiles -Minimum 0 -Maximum 100000
$attemptsValue = Convert-RepairCliInteger -Name 'Attempts' -Value $Attempts -Minimum 0 -Maximum 100
$scopeOverlapValue = Convert-RepairCliBoolean -Name 'ScopeOverlap' -Value $ScopeOverlap
$externalEffectsValue = Convert-RepairCliBoolean -Name 'ExternalEffectsAmbiguous' -Value $ExternalEffectsAmbiguous
$evidenceCurrentValue = Convert-RepairCliBoolean -Name 'EvidenceCurrent' -Value $EvidenceCurrent

$decision = Resolve-OrchestrationLocalizedRepair -Severity $severityValue -ChangedFiles $changedFilesValue `
    -ScopeOverlap $scopeOverlapValue -ExternalEffectsAmbiguous $externalEffectsValue `
    -EvidenceCurrent $evidenceCurrentValue -Attempts $attemptsValue -FailureClass $failureClassValue
$output = [ordered]@{
    ok = [bool]$decision.ok
    decision = [string]$decision.decision
    reason = [string]$decision.reason
    constraints = @($decision.constraints)
}
Write-Output (ConvertTo-Json -InputObject $output -Depth 5 -Compress)
exit 0
