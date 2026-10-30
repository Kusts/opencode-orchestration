<#!
.SYNOPSIS
    Etapa 4 REAL - modelo efetivo, fallback e prova via executor injetavel.
.DESCRIPTION
    Sem rede/spawn. PS 5.1, ASCII-only. Nenhuma escrita concorrente.
    ME7 varre a lib de verdade (assert real, sem tautologia).
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
    # 1. Tarefa simples: selecao economica, sem prova => PROOF_ABSENT fail-closed
    $s = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-simple' -Risk 'low' -Complexity 'simple'
    Assert-ME (([string]$s.status -ceq 'PROOF_ABSENT')) '[ME1] simples sem prova => PROOF_ABSENT' ([string]$s.status)
    Assert-ME ((-not [bool]$s.ok)) '[ME1] sem prova nao aprova (fail-closed)' ([string]$s.ok)
    Assert-ME (([string]$s.reason -cne 'executed')) '[ME1] nunca reason=executed sem prova' ([string]$s.reason)
    Assert-ME (([string]$s.selection.Tier -in @('T1','T2'))) '[ME1] tier economico' ([string]$s.selection.Tier)
    Assert-ME (-not [string]::IsNullOrWhiteSpace([string]$s.subagent_model_param)) '[ME1] subagent model param projetado' ([string]$s.subagent_model_param)
    Assert-ME (([string]$s.execution_log.effective_model -ceq [string]$s.subagent_model_param)) '[ME1] log mostra efetivo' ''
    Assert-ME ((-not [bool]$s.grants_authority)) '[ME1] sem autoridade' ''
    # 2. Impasse justificado + evento real provado => EXECUTED_VERIFIED
    $selHard = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true -IgnoreUserConfig $true -NativeModelOverrideProven $true
    $e = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-hard' -Risk 'medium' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true -NativeModelOverrideProven $true -ExecutedModelEvent @{ Model = [string]$selHard.CatalogModel }
    Assert-ME ([bool]$e.ok) '[ME2] impasse com prova resolve' ([string]$e.reason)
    Assert-ME (([string]$e.status -ceq 'EXECUTED_VERIFIED')) '[ME2] status EXECUTED_VERIFIED' ([string]$e.status)
    Assert-ME (([string]$e.verification.ProofStatus -ceq 'EXACT_MATCH')) '[ME2] prova EXACT_MATCH' ([string]$e.verification.ProofStatus)
    # 3. Escalonamento nao autorizado recusado ou degradado, nunca T4 silencioso
    $u = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-unauth' -Risk 'high' -Complexity 'complex' -FailureCount 3 -ProviderCostAuthorized $false
    if ([bool]$u.ok) { Assert-ME (([string]$u.selection.Tier -cne 'T4')) '[ME3] sem custo nao usa T4' ([string]$u.selection.Tier) }
    else { Assert-ME (([string]$u.reason -ceq 'unauthorized-escalation-refused') -or ([string]$u.status -ceq 'PROOF_ABSENT')) '[ME3] escalonamento recusado ou fail-closed' ([string]$u.reason) }
    Assert-ME (([string]$u.status -in @('PROOF_ABSENT','SELECTED','DISPATCHED','EXECUTED_VERIFIED'))) '[ME3] status na taxonomia' ([string]$u.status)
    # 4. Falha de contexto nao escala
    $c1 = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-ctx' -Risk 'low' -Complexity 'simple' -FailureCount 3 -IsContextFailure $true
    $c0 = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-ctx' -Risk 'low' -Complexity 'simple' -FailureCount 0
    Assert-ME (([string]$c1.selection.Tier -ceq [string]$c0.selection.Tier)) '[ME4] contexto nao confunde com incapacidade' (([string]$c1.selection.Tier)+' vs '+([string]$c0.selection.Tier))
    # 5. Override desabilitado recusado
    $d = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-dis' -Risk 'low' -Complexity 'simple' -RequestedModelOverride 'opencode/deepseek-v4.1-flash-free'
    Assert-ME ((-not [bool]$d.ok) -and ([string]$d.reason -ceq 'model-disabled')) '[ME5] modelo desabilitado recusado' ([string]$d.reason)
    # 6. Sem prova de override => PROOF_ABSENT, efetivo e fallback conservador
    $p = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-proof' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $false
    Assert-ME (([string]$p.execution_log.proof_status -ceq 'PROOF_ABSENT')) '[ME6] sem prova => PROOF_ABSENT' ([string]$p.execution_log.proof_status)
    Assert-ME (([string]$p.subagent_model_param -ceq [string]$p.selection.FallbackToken)) '[ME6] efetivo e fallback conservador' ([string]$p.subagent_model_param)
    Assert-ME (([string]$p.reason -ceq 'proof-absent-fallback')) '[ME6] reason proof-absent-fallback' ([string]$p.reason)
    # 7. Sem config concorrente: varredura real da lib + nenhuma escrita no cwd
    $libPath = Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1'
    $libLines = Get-Content -LiteralPath $libPath
    $bad = @()
    foreach ($ln in $libLines) {
        $isWrite = ($ln -match 'Set-Content|Add-Content|Out-File|New-Item')
        $isRef = ($ln -match 'models\.json|models\.jsonc|AgentProfile')
        if ($isWrite -and $isRef) { $bad += $ln.Trim() }
    }
    Assert-ME (($bad.Count -eq 0)) '[ME7] lib sem escrita concorrente (scan real)' ([string]($bad -join ' | '))
    $cwdModels = Join-Path (Get-Location) 'models.json'
    $cwdModelsC = Join-Path (Get-Location) 'models.jsonc'
    $existedBefore = (Test-Path -LiteralPath $cwdModels) -or (Test-Path -LiteralPath $cwdModelsC)
    $px = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-scan' -Risk 'low' -Complexity 'simple'
    $createdNow = $false
    if (-not $existedBefore) {
        $createdNow = (Test-Path -LiteralPath $cwdModels) -or (Test-Path -LiteralPath $cwdModelsC)
    }
    Assert-ME ((-not $createdNow)) '[ME7] nenhuma escrita no cwd durante o teste' ''
    # 8. Negativo: sem executor e sem evento => PROOF_ABSENT, nunca EXECUTED
    $n = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-neg' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $false
    Assert-ME (([string]$n.status -ceq 'PROOF_ABSENT')) '[ME8] sem executor/evento => PROOF_ABSENT' ([string]$n.status)
    Assert-ME (([string]$n.reason -cne 'executed') -and ([string]$n.reason -cne 'executed-verified')) '[ME8] nao afirma EXECUTED sem prova' ([string]$n.reason)
    Assert-ME ((-not [bool]$n.ok)) '[ME8] fail-closed' ([string]$n.ok)
    # 9. Dispatch ok sem evento observavel => DISPATCHED, nao EXECUTED_VERIFIED
    $execNoEvent = { param($Model,$Agent,$TaskId) return @{} }
    $di = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-disp' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $true -DispatchExecutor $execNoEvent
    Assert-ME (([string]$di.status -ceq 'DISPATCHED')) '[ME9] dispatch sem evento => DISPATCHED' ([string]$di.status)
    Assert-ME (([string]$di.status -cne 'EXECUTED_VERIFIED')) '[ME9] nao afirma EXECUTED_VERIFIED sem verificacao' ([string]$di.status)
    Assert-ME ($null -eq $di.verification) '[ME9] sem verificacao' ''
    # 10. Executor deterministico snapshot exato => EXECUTED_VERIFIED
    $selSnap = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'low' -Complexity 'simple' -FailureCount 0 -ProviderCostAuthorized $false -IgnoreUserConfig $true -NativeModelOverrideProven $true
    $want = [string]$selSnap.CatalogModel
    $execExact = { param($Model,$Agent,$TaskId) return @{ Model = $Model } }
    $v = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-snap' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $true -DispatchExecutor $execExact
    Assert-ME (([string]$v.status -ceq 'EXECUTED_VERIFIED')) '[ME10] snapshot exato => EXECUTED_VERIFIED' ([string]$v.status)
    Assert-ME (([string]$v.verification.ProofStatus -ceq 'EXACT_MATCH')) '[ME10] prova EXACT_MATCH' ([string]$v.verification.ProofStatus)
    # 11. Executor mismatch sem fallback => UNAUTHORIZED_MISMATCH / PROOF_ABSENT
    $execOther = { param($Model,$Agent,$TaskId) return @{ Model = 'openai/gpt-6-astra' } }
    $w = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-mismatch' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $true -DispatchExecutor $execOther
    Assert-ME (([string]$w.verification.ProofStatus -ceq 'UNAUTHORIZED_MISMATCH')) '[ME11] mismatch => UNAUTHORIZED_MISMATCH' ([string]$w.verification.ProofStatus)
    Assert-ME (([string]$w.status -ceq 'PROOF_ABSENT')) '[ME11] status PROOF_ABSENT fail-closed' ([string]$w.status)
    Assert-ME ((-not [bool]$w.ok)) '[ME11] mismatch nao aprova' ([string]$w.ok)
    # 12. Selecao provada sem dispatch => SELECTED
    $selOnly = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-sel' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $true
    Assert-ME (([string]$selOnly.status -ceq 'SELECTED')) '[ME12] provado sem dispatch => SELECTED' ([string]$selOnly.status)
    Assert-ME (([string]$selOnly.reason -ceq 'selected')) '[ME12] reason selected' ([string]$selOnly.reason)
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }; exit 0
} catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message); $script:failed++
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed); exit 1
}
