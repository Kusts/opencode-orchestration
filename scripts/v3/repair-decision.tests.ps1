<#
.SYNOPSIS
    Process-level tests for repair-decision.ps1.
    PowerShell 5.1 and PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:CliPath = Join-Path $PSScriptRoot 'repair-decision.ps1'
$script:PowerShellPath = [string](Get-Process -Id $PID).Path

function Assert-RepairDecision {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ('[PASS] ' + $Name)
        $script:Passed++
    }
    else {
        Write-Host ('[FAIL] ' + $Name + $(if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' -- ' + $Detail }))
        $script:Failed++
    }
}

function Invoke-RepairDecisionCli {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellPath
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:CliPath + '" ' + (@($CliArgs) -join ' ')
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
    return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Stdout = $stdout.Trim(); Stderr = $stderr.Trim() }
}

function Assert-RepairResult {
    param([string]$Name, [string[]]$CliArgs, [string]$ExpectedDecision, [string]$ExpectedReason)
    $run = Invoke-RepairDecisionCli -CliArgs $CliArgs
    $json = $null
    try { $json = $run.Stdout | ConvertFrom-Json } catch { }
    $ok = ($run.ExitCode -eq 0) -and ($null -ne $json) -and [bool]$json.ok -and
        ([string]$json.decision -ceq $ExpectedDecision) -and ([string]$json.reason -ceq $ExpectedReason)
    Assert-RepairDecision $ok $Name (("exit=" + $run.ExitCode + '; stdout=' + $run.Stdout + '; stderr=' + $run.Stderr))
}

Assert-RepairResult 'LOCAL_REPAIR for one localized file and zero attempts' @() 'LOCAL_REPAIR' 'localized-finding'
Assert-RepairResult 'REPLAN for ambiguous external effects' @('-ExternalEffectsAmbiguous', 'true') 'REPLAN' 'ambiguous-external-effect'
Assert-RepairResult 'REPLAN for stale evidence' @('-EvidenceCurrent', 'false') 'REPLAN' 'evidence-drift'
Assert-RepairResult 'REPLAN for structural failure' @('-FailureClass', 'structural') 'REPLAN' 'structural-failure'
Assert-RepairResult 'REPLAN for critical severity' @('-Severity', 'critical') 'REPLAN' 'critical-scope'
Assert-RepairResult 'REPLAN for unknown failure class' @('-FailureClass', 'unknown') 'REPLAN' 'failure-class-unknown'
Assert-RepairResult 'ESCALATE after two attempts' @('-Attempts', '2') 'ESCALATE' 'retry-budget-exhausted'

$negativeAttempts = Invoke-RepairDecisionCli -CliArgs @('-Attempts', '-1')
Assert-RepairDecision (($negativeAttempts.ExitCode -eq 2) -and ($negativeAttempts.Stderr -match '-Attempts must be an integer')) 'negative attempts rejected with exit 2' $negativeAttempts.Stderr
$negativeFiles = Invoke-RepairDecisionCli -CliArgs @('-ChangedFiles', '-1')
Assert-RepairDecision (($negativeFiles.ExitCode -eq 2) -and ($negativeFiles.Stderr -match '-ChangedFiles must be an integer')) 'negative changed-files rejected with exit 2' $negativeFiles.Stderr
$badSeverity = Invoke-RepairDecisionCli -CliArgs @('-Severity', 'urgent')
Assert-RepairDecision (($badSeverity.ExitCode -eq 2) -and ($badSeverity.Stderr -match '-Severity must be')) 'invalid severity rejected with exit 2' $badSeverity.Stderr

Write-Host ''
Write-Host ('REPAIR-DECISION: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
if ($script:Failed -gt 0) { exit 1 }
exit 0
