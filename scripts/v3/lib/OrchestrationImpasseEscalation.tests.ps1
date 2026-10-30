<#!
.SYNOPSIS
    Etapa 3 FULL_DELIVERY — testes do sinal de impasse.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationImpasseEscalation.ps1')

$script:passed = 0
$script:failed = 0
function Assert-IE {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    # stagnation >= 3 => impasse
    $d1 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -StagnationThreshold 3
    Assert-IE ([bool]$d1.impasse) '[IE1] stagnation 3 => impasse' ''
    Assert-IE ([bool]$d1.debugger_recommended) '[IE1] debugger recommended' ''
    Assert-IE ([bool]$d1.jev_recommended) '[IE1] jev recommended' ''
    Assert-IE (-not [bool]$d1.grants_authority) '[IE1] no authority granted' ''

    # stagnation 2 => no impasse
    $d2 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 2; meaningful = $false; reason = 'no-change' } -StagnationThreshold 3
    Assert-IE (-not [bool]$d2.impasse) '[IE2] stagnation 2 => no impasse' ''

    # terminal failure => impasse
    $d3 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 0; meaningful = $false; reason = 'no-change' } -LastFailure 'terminal'
    Assert-IE ([bool]$d3.impasse) '[IE3] terminal failure => impasse' ''
    Assert-IE ($d3.reason -ceq 'terminal-failure') '[IE3] reason terminal-failure' ''

    # regression => impasse
    $d4 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 0; meaningful = $false; reason = 'regressed' }
    Assert-IE ([bool]$d4.impasse) '[IE4] regression => impasse' ''
    Assert-IE ($d4.reason -ceq 'regression') '[IE4] reason regression' ''

    # meaningful progress => no impasse
    $d5 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 0; meaningful = $true; reason = '' }
    Assert-IE (-not [bool]$d5.impasse) '[IE5] meaningful progress => no impasse' ''

    # high risk => advisor + escalate tier
    $d6 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'high'
    Assert-IE ([bool]$d6.advisor_recommended) '[IE6] high risk => advisor recommended' ''
    Assert-IE ($d6.model_router_action -ceq 'escalate-tier') '[IE6] high risk => escalate-tier' ''

    # low risk => no advisor, hold tier
    $d7 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low'
    Assert-IE (-not [bool]$d7.advisor_recommended) '[IE7] low risk => no advisor' ''
    Assert-IE ($d7.model_router_action -ceq 'hold-tier') '[IE7] low risk => hold-tier' ''

    # unknown risk => fail-closed to medium
    $d8 = Test-IEImpasseSignal -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'bogus'
    Assert-IE ($d8.task_risk -ceq 'medium') '[IE8] unknown risk => medium' ''

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}