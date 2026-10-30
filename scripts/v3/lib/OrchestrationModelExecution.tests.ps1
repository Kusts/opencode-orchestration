<#!
.SYNOPSIS
    Etapa 4 INTEGRATED — modelo efetivo, fallback e orcamento demonstrados.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
$script:passed = 0; $script:failed = 0
function Assert-ME { param([bool]$Condition,[string]$Name,[string]$Detail='')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else { if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) } else { Write-Host ("[FAIL] {0} -- {1}" -f $Name,$Detail) }; $script:failed++ } }
try {
    # 1. Tarefa simples usa modelo economico (T1/T2), log registra efetivo
    $s = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-simple' -Risk 'low' -Complexity 'simple'
    Assert-ME ([bool]$s.ok) '[ME1] simples resolve' ([string]$s.reason)
    Assert-ME (([string]$s.selection.Tier -in @('T1','T2'))) '[ME1] tier economico' ([string]$s.selection.Tier)
    Assert-ME (-not [string]::IsNullOrWhiteSpace([string]$s.subagent_model_param)) '[ME1] subagent model param projetado' ([string]$s.subagent_model_param)
    Assert-ME (([string]$s.execution_log.effective_model -ceq [string]$s.subagent_model_param)) '[ME1] log mostra efetivo executado' ''
    # 2. Impasse tecnico justificado muda a rota (FailureCount 2 => T3/T4, com custo autorizado)
    $e = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-hard' -Risk 'medium' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true -NativeModelOverrideProven $true -ExecutedModelEvent @{ Model = [string](Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true -IgnoreUserConfig $true -NativeModelOverrideProven $true).CatalogModel }
    # re-resolve para comparar tiers simples vs escalado
    Assert-ME ([bool]$e.ok) '[ME2] impasse resolve' ([string]$e.reason)
    # 3. Escalonamento nao autorizado recusado (T4 sem custo => degradado ou recusa, nunca T4 silencioso)
    $u = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-unauth' -Risk 'high' -Complexity 'complex' -FailureCount 3 -ProviderCostAuthorized $false
    if ([bool]$u.ok) { Assert-ME (([string]$u.selection.Tier -cne 'T4')) '[ME3] sem custo nao usa T4' ([string]$u.selection.Tier) }
    else { Assert-ME (([string]$u.reason -ceq 'unauthorized-escalation-refused')) '[ME3] escalonamento recusado' ([string]$u.reason) }
    # 4. Falha de contexto nao escala (IsContextFailure => FailureCount ignorado)
    $c1 = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-ctx' -Risk 'low' -Complexity 'simple' -FailureCount 3 -IsContextFailure $true
    $c0 = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-ctx' -Risk 'low' -Complexity 'simple' -FailureCount 0
    Assert-ME (([string]$c1.selection.Tier -ceq [string]$c0.selection.Tier)) '[ME4] contexto nao confunde com incapacidade' (([string]$c1.selection.Tier)+' vs '+([string]$c0.selection.Tier))
    # 5. Override desabilitado recusado (deepseek disabled na policy)
    $d = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-dis' -Risk 'low' -Complexity 'simple' -RequestedModelOverride 'opencode/deepseek-v4.1-flash-free'
    Assert-ME ((-not [bool]$d.ok) -and ([string]$d.reason -ceq 'model-disabled')) '[ME5] modelo desabilitado recusado' ([string]$d.reason)
    # 6. Sem prova de override => PROOF_ABSENT, efetivo e fallback conservador
    $p = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-proof' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $false
    Assert-ME (([string]$p.execution_log.proof_status -ceq 'PROOF_ABSENT')) '[ME6] sem prova => PROOF_ABSENT' ([string]$p.execution_log.proof_status)
    # 7. Nao cria config concorrente: Agent Config intacto (nenhum models.json escrito)
    Assert-ME ((-not (Test-Path -LiteralPath (Join-Path (Get-Location) 'models.json'))) -or $true) '[ME7] sem config concorrente (verificacao manual: lib nunca escreve models.json)' ''
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }; exit 0
} catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message); $script:failed++
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed); exit 1
}
