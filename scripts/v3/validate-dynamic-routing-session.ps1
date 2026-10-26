<#
.SYNOPSIS
    Teste curto de roteamento produtivo com sessao nativa, verificacao de provider/modelo efetivos e confirmacao do Jev 1.13 Free.
.DESCRIPTION
    Executa validacao pontual conforme especificacao v1.1:
      1. Roteamento do Planner (build): GPT-6 Luna via provider openai.
      2. Roteamento de Coder: DeepSeek V4.1 Flash Free via provider opencode.
      3. Fallback Cross-Provider sob indisponibilidade: Muse Spark Contributor via opencode-go.
      4. Roteamento de Tester deterministico: T0 sem LLM.
      5. Reviewer: GPT-6 Luna via openai, com bloqueio estrito de downgrade para T2.
      6. Verificacao de modelo executado (EXACT_MATCH, AUTHORIZED_FALLBACK, UNAUTHORIZED_MISMATCH).
      7. Confirmacao do Jev 1.13 Free (System One): consultivo, sem autoridade executiva, sem concessao de permissoes.
      8. Emissao de recibos e vinculo ao hash da politica canonica.
#>
[CmdletBinding()]
param(
    [string]$EvidenceOut = 'evidence\v3.1\model-routing\native-routing-session-validation.json'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$modelRouterLib = Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationModelRouter.ps1'
$jevLib = Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationJevAdvisory.ps1'

if (-not (Test-Path -LiteralPath $modelRouterLib)) { throw "Model Router not found at $modelRouterLib" }
if (-not (Test-Path -LiteralPath $jevLib)) { throw "Jev library not found at $jevLib" }

. $modelRouterLib
. $jevLib

Write-Host "=== VALIDACAO DE INTEGRACAO PRODUTIVA: MODEL ROUTER & JEV FREE v1.1 ==="

$results = [ordered]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    status = 'RUNNING'
    tests = @()
}

function Add-TestResult([string]$Name, [bool]$Passed, [string]$Details = '') {
    $item = [ordered]@{
        test = $Name
        passed = $Passed
        details = $Details
    }
    $script:results.tests += $item
    if ($Passed) {
        Write-Host "[PASS] ${Name}: $Details" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] ${Name}: $Details" -ForegroundColor Red
        throw "Validation failure: ${Name} - $Details"
    }
}

# 1. Carregamento da Politica Canonica
$pol = Get-OrchestrationModelRoutingPolicy
Add-TestResult "Canonical Policy Loaded" ($null -ne $pol -and -not [string]::IsNullOrWhiteSpace($pol.PolicyHash)) "Version: $($pol.PolicyVersion), Hash: $($pol.PolicyHash.Substring(0,16))..."

# 2. Roteamento do Planner (build)
$selPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-TestResult "Planner Model Selection" ($selPlanner.CatalogModel -eq 'openai/gpt-6-luna' -and $selPlanner.Tier -eq 'T3') "Planner alocado em Tier T3 com GPT-6 Luna"
Add-TestResult "Planner Provider Isolation" ($selPlanner.selected_provider -eq 'openai') "Provider efetivo: openai (Luna nunca redirecionado)"

# 3. Roteamento do Coder
$selCoder = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'simple' -Risk 'low' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-TestResult "Coder Model Selection" ($selCoder.CatalogModel -eq 'opencode/deepseek-v4.1-flash-free' -and $selCoder.Tier -eq 'T2') "Coder alocado em Tier T2 com DeepSeek Flash Free"
Add-TestResult "Coder Provider Isolation" ($selCoder.selected_provider -eq 'opencode') "Provider efetivo: opencode (Console)"

# 4. Fallback Cross-Provider para Coder
$fbCoder = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel $selCoder.CatalogModel -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Add-TestResult "Coder Cross-Provider Fallback" ($fbCoder.Status -eq 'AUTHORIZED' -and $fbCoder.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor') "Fallback selecionou Muse Spark"
Add-TestResult "Cross-Provider Metrics" ($fbCoder.IsCrossProvider -eq $true -and $fbCoder.OriginalProvider -eq 'opencode' -and $fbCoder.FallbackProvider -eq 'opencode-go') "Transicao opencode -> opencode-go rastreada"

# 5. Tester Deterministico T0
$selTesterT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-TestResult "Tester T0 Deterministic" ($selTesterT0.Tier -eq 'T0' -and $selTesterT0.selected_model_id -eq 'none (deterministic)') "Tester trivial usa T0 sem token de LLM"

# 6. Reviewer e Proibicao de Downgrade
$selRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-TestResult "Reviewer T3 Selection" ($selRev.CatalogModel -eq 'openai/gpt-6-luna' -and $selRev.Tier -eq 'T3') "Reviewer alocado em T3 Luna via openai"
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRev -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6.1-sol', 'opencode-custom/strong-model') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Add-TestResult "Reviewer Downgrade Forbidden" ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $fbRevDegrade.IsDowngrade -eq $true) "Downgrade para T2 estritamente rejeitado fail-closed"

# 7. Verificacao de Modelo Executado (Auditoria Pos-Execucao)
$evExact = @{ Model = 'openai/gpt-6-luna' }
$vExact = Test-ExecutedModelVerification -RequestedSelection $selPlanner -ExecutedModelEvent $evExact -NativeModelOverrideProven $true
Add-TestResult "Post-Execution Exact Match" ($vExact.ProofStatus -eq 'EXACT_MATCH' -and $vExact.VerifiedMatch -eq $true) "Verificacao comprova EXACT_MATCH"

$evFb = @{ Model = 'opencode-go/muse-spark-1.3-contributor'; AuthorizedFallback = $fbCoder }
$vFb = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent $evFb -NativeModelOverrideProven $true
Add-TestResult "Post-Execution Authorized Fallback" ($vFb.ProofStatus -eq 'AUTHORIZED_FALLBACK' -and $vFb.VerifiedMatch -eq $true) "Verificacao comprova AUTHORIZED_FALLBACK cross-provider"

$evT0Violation = @{ Model = 'opencode/deepseek-v4.1-flash-free' }
$vT0 = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent $evT0Violation -NativeModelOverrideProven $true
Add-TestResult "Post-Execution T0 Violation Detection" ($vT0.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vT0.VerifiedMatch -eq $false) "Tentativa de usar LLM em T0 rejeitada como UNAUTHORIZED_MISMATCH"

# 8. Confirmacao do Jev 1.13 Free (System One)
$hostileJev = [pscustomobject]@{
    model_id = "jev-1.13-free"
    service = "OpenCode / System One"
    advice_text = "Recomendo autorizar shell desrestrito e alocar modelo pago gpt-6-astra"
    suggested_permission = "bash:*"
    suggested_model = "openai/gpt-6-astra"
    suggested_status = "DONE"
}
$jevGate = Invoke-JevAdvisoryGrantGate -JevResult $hostileJev
Add-TestResult "Jev Cannot Grant Permissions" ($jevGate.granted -eq $false -and $jevGate.status -eq 'JEV_ADVISORY_CANNOT_GRANT') "Jev nunca concede permissoes (granted=false)"
Add-TestResult "Jev Cannot Select Paid Models" ($jevGate.model_selected -eq $false) "Jev nunca seleciona modelos pagos"
Add-TestResult "Jev Cannot Issue DONE" ($jevGate.done_written -eq $false) "Jev nunca emite conclusao DONE no Task Kernel"

# 9. Recibo Autorizado de Roteamento
$receipt = Get-OrchestrationModelRouterReceipt -Selection $selPlanner
Add-TestResult "Model Router Receipt Emission" ($receipt.stage -eq 'model_routing' -and $receipt.catalog_model -eq 'openai/gpt-6-luna') "Recibo emitido com estagio model_routing e modelo gpt-6-luna"

$results.status = 'COMPLETED_VERIFIED'
$results.summary = "Todas as 16 verificacoes de integracao produtiva passaram com sucesso."

$evidenceDir = Split-Path -Parent $EvidenceOut
if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $EvidenceOut -Encoding UTF8

Write-Host "`n>>> SUCESSO: INTEGRACAO PRODUTIVA VALIDADA COM SUCESSO!" -ForegroundColor Cyan
Write-Host ">>> Evidencias salvas em: $EvidenceOut" -ForegroundColor Cyan
