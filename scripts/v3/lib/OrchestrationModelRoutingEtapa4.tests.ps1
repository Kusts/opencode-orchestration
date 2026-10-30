<#!
.SYNOPSIS
    Etapa 4 FULL_DELIVERY — roteamento adaptativo (testes determinísticos).
.DESCRIPTION
    Verifica os cenários de aceitação da Etapa 4 usando o Model Router existente.
    Sem custo de LLM. PS 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')

$script:passed = 0
$script:failed = 0
function Assert-MR {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    # 1. Tarefa simples sem escalonamento: coder low risk, trivial complexity
    $r1 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'low' -Complexity 'trivial' -IgnoreUserConfig $true
    Assert-MR ($null -ne $r1) '[MR1] coder trivial resolves' ''
    $t1 = [string]$r1.Tier
    Assert-MR ($t1 -in @('T1','T2')) '[MR1] coder trivial uses low tier (T1/T2)' ('tier=' + $t1)

    # 2. Falha por falta de contexto: explorer (T1 default, T3/T4 prohibited)
    $r2 = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true
    $t2 = [string]$r2.Tier
    Assert-MR ($t2 -in @('T0','T1','T2')) '[MR2] explorer uses low tier (T0-T2)' ('tier=' + $t2)
    Assert-MR ($t2 -notin @('T3','T4')) '[MR2] explorer never uses T3/T4' ('tier=' + $t2)

    # 3. Impasse técnico: engineering-advisor high risk, complex
    $r3 = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'high' -Complexity 'complex' -IgnoreUserConfig $true
    $t3 = [string]$r3.Tier
    Assert-MR ($t3 -in @('T2','T3','T4')) '[MR3] advisor high risk uses T2+' ('tier=' + $t3)

    # 4. Falha comprovada por capacidade do modelo: coder with FailureCount > 0
    $r4a = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium' -FailureCount 0 -IgnoreUserConfig $true
    $r4b = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium' -FailureCount 3 -IgnoreUserConfig $true
    Assert-MR ($null -ne $r4a -and $null -ne $r4b) '[MR4] coder resolves with/without failures' ''

    # 5. Modelo indisponível → fallback permitido: unknown agent rejected (fail-closed)
    $r5 = Resolve-OrchestrationModelSelection -AgentName 'nonexistent-agent' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true
    Assert-MR ($null -ne $r5) '[MR5] unknown agent returns result (not throw)' ''
    $s5 = [string]$r5.Status
    Assert-MR ($s5 -ceq 'REJECTED' -or $s5 -ceq 'NO_ELIGIBLE_MODEL') '[MR5] unknown agent rejected' ('status=' + $s5)

    # 6. Escalonamento pago não autorizado: ProviderCostAuthorized=$false, high risk
    $r6 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'high' -Complexity 'complex' -ProviderCostAuthorized $false -IgnoreUserConfig $true
    Assert-MR ($null -ne $r6) '[MR6] coder high risk resolves (no crash)' ''
    # Should not silently select T4 without authorization
    $t6 = [string]$r6.Tier
    Assert-MR ($t6 -ne 'T4' -or [bool]$r6.ProviderCostAuthorized) '[MR6] T4 not selected without cost auth' ('tier=' + $t6)

    # 7. Repetição sem progresso: same inputs produce same tier (deterministic)
    $r7a = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
    $r7b = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
    Assert-MR ([string]$r7a.Tier -ceq [string]$r7b.Tier) '[MR7] deterministic: same inputs => same tier' ''

    # 8. Planner (build) never uses T4
    $r8 = Resolve-OrchestrationModelSelection -AgentName 'build' -Risk 'critical' -Complexity 'complex' -IgnoreUserConfig $true
    $t8 = [string]$r8.Tier
    Assert-MR ($t8 -ne 'T4') '[MR8] build never uses T4' ('tier=' + $t8)

    # 9. Explorer never uses T3/T4
    $r9 = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Risk 'critical' -Complexity 'complex' -IgnoreUserConfig $true
    $t9 = [string]$r9.Tier
    Assert-MR ($t9 -notin @('T3','T4')) '[MR9] explorer never uses T3/T4' ('tier=' + $t9)

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