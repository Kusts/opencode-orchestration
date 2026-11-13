<#!
.SYNOPSIS
    Testes da decisao de reparo localizado (M5, issue #103).
.DESCRIPTION
    Funcao pura; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationLocalizedRepair.ps1')

$script:passed = 0
$script:failed = 0
function Assert-LR {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

try {
    $local = Resolve-OrchestrationLocalizedRepair -Severity 'medium' -ChangedFiles 1 -ScopeOverlap $true -Attempts 0 -FailureClass 'localized'
    Assert-LR (([string]$local.decision -ceq 'LOCAL_REPAIR')) '[LR1] finding localizado => reparo local' ([string]$local.decision)
    Assert-LR ((@($local.constraints) -contains 'same-task')) '[LR1] mantem a mesma Task' ([string]($local.constraints -join ','))

    $external = Resolve-OrchestrationLocalizedRepair -ExternalEffectsAmbiguous $true
    Assert-LR (([string]$external.decision -ceq 'REPLAN')) '[LR2] efeito externo ambiguo => replan' ([string]$external.decision)
    Assert-LR (([string]$external.reason -ceq 'ambiguous-external-effect')) '[LR2] reason correto' ([string]$external.reason)

    $stale = Resolve-OrchestrationLocalizedRepair -EvidenceCurrent $false
    Assert-LR (([string]$stale.decision -ceq 'REPLAN')) '[LR3] evidencia obsoleta => replan' ([string]$stale.decision)

    $budget = Resolve-OrchestrationLocalizedRepair -Attempts 2
    Assert-LR (([string]$budget.decision -ceq 'ESCALATE')) '[LR4] 2 tentativas => escalate' ([string]$budget.decision)
    Assert-LR (([string]$budget.reason -ceq 'retry-budget-exhausted')) '[LR4] reason correto' ([string]$budget.reason)

    $critical = Resolve-OrchestrationLocalizedRepair -Severity 'critical' -ChangedFiles 1
    Assert-LR (([string]$critical.decision -ceq 'REPLAN')) '[LR5] critical => replan' ([string]$critical.decision)

    $structural = Resolve-OrchestrationLocalizedRepair -FailureClass 'structural'
    Assert-LR (([string]$structural.decision -ceq 'REPLAN')) '[LR6] falha estrutural => replan' ([string]$structural.decision)

    $unknown = Resolve-OrchestrationLocalizedRepair -FailureClass 'unknown'
    Assert-LR (([string]$unknown.decision -ceq 'REPLAN')) '[LR7] classe desconhecida => replan' ([string]$unknown.decision)

    $broad = Resolve-OrchestrationLocalizedRepair -ChangedFiles 5 -ScopeOverlap $true
    Assert-LR (([string]$broad.decision -ceq 'REPLAN')) '[LR8] escopo amplo => replan' ([string]$broad.decision)

    $noOverlap = Resolve-OrchestrationLocalizedRepair -ChangedFiles 1 -ScopeOverlap $false
    Assert-LR (([string]$noOverlap.decision -ceq 'REPLAN')) '[LR9] sem sobreposicao de escopo => replan' ([string]$noOverlap.decision)

    $bad = Resolve-OrchestrationLocalizedRepair -ChangedFiles -1
    Assert-LR ((-not [bool]$bad.ok) -and ([string]$bad.decision -ceq 'INVALID')) '[LR10] entrada invalida falha fechado' ([string]$bad.reason)
}
finally { }

Write-Host ''
Write-Host ('LOCALIZED-REPAIR: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
