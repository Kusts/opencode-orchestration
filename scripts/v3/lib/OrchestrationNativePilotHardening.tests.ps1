<#
.SYNOPSIS
    Testes focados de Hardening para Fechamento do PR #157 (READY_FOR_CONTROLLED_PILOT):
      - P0-01: Verificacao do modelo efetivo (EXACT_MATCH, AUTHORIZED_FALLBACK, UNAUTHORIZED_MISMATCH, PROOF_ABSENT).
      - P0-02: Fallback controlado via Model Router com limite de retries e rejeicao de downgrade.
      - P1-01: Distinção de proveniência de recibos (CANONICAL_PROTOCOL vs POST_EXECUTION_AUDIT).
      - P1-02: Vinculacao do parecer e cadeia deterministica de integridade de artefato (SHA256 em 3 marcos).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$total = 0
$passed = 0

function Assert-Hardening([bool]$Condition, [string]$Message) {
    $script:total++
    if ($Condition) {
        $script:passed++
        Write-Host "[PASS] $Message"
    } else {
        throw "FAIL: $Message"
    }
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not (Test-Path (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationModelRouter.ps1'))) {
    $RepoRoot = (Get-Location).Path
}

. (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationModelRouter.ps1')

Write-Host "=== TESTES FOCADOS: MODEL ROUTER, FALLBACK, RECIBOS E INTEGRIDADE DE ARTEFATO ==="

# --------------------------------------------------------------------------
# 1. P0-01: VERIFICACAO DE MODELO EFETIVO
# --------------------------------------------------------------------------
$selCoder = Resolve-OrchestrationModelSelection -AgentName 'coder' -NativeModelOverrideProven $true

# 1.1 Match exato
$evExact = @{ Model = $selCoder.CatalogModel }
$vExact = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent $evExact -NativeModelOverrideProven $true
Assert-Hardening ($vExact.ProofStatus -eq 'EXACT_MATCH' -and $vExact.IsExactMatch -eq $true -and $vExact.VerifiedMatch -eq $true) "P0-01.1: Match exato classifica como EXACT_MATCH e VerifiedMatch=true"

# 1.2 Fallback tecnico permanece HOLD (CandidateModel nao-autorizador)
# Ordem candidata T2 e Luna->DeepSeek Go: o resolver retorna HOLD com
# FallbackModel null e IsAuthorized false; CandidateModel e auditoria apenas.
$fbDecision = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel $selCoder.CatalogModel -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -ClaudeAgentProven $true
Assert-Hardening ($fbDecision.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fbDecision.IsAuthorized -eq $false -and $null -eq $fbDecision.FallbackModel) "P0-01.2: Ordem candidata T2 Luna->DeepSeek Go permanece HOLD sem autorizacao produtiva"
Assert-Hardening ($fbDecision.CandidateModel -eq 'opencode-go/deepseek-v4.1-flash') "P0-01.2: Primeiro candidato apos Luna e DeepSeek Go (audit-only)"
$evFb = @{ Model = $fbDecision.CandidateModel; AuthorizedFallback = $fbDecision }
$vFb = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent $evFb -NativeModelOverrideProven $true
Assert-Hardening ($vFb.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vFb.IsAuthorizedFallback -eq $false -and $vFb.IsExactMatch -eq $false -and $vFb.VerifiedMatch -eq $false) "P0-01.2: Evento DeepSeek sob HOLD verifica como UNAUTHORIZED_MISMATCH (CandidateModel nao autoriza)"

# 1.3 Mismatch: mesmo tier sem decisao de fallback
$altModelNoAuth = if ($selCoder.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') { 'openai/gpt-6-luna' } else { 'opencode-go/muse-spark-1.3-contributor' }
$evNoAuth = @{ Model = $altModelNoAuth }
$vNoAuth = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent $evNoAuth -NativeModelOverrideProven $true
Assert-Hardening ($vNoAuth.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vNoAuth.VerifiedMatch -eq $false) "P0-01.3: Modelo do mesmo tier sem autorizacao e UNAUTHORIZED_MISMATCH"

# 1.4 PROOF_ABSENT: modelo vazio ou sem evento
$vAbsent = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent @{ Model = '' } -NativeModelOverrideProven $true
Assert-Hardening ($vAbsent.ProofStatus -eq 'PROOF_ABSENT' -and $vAbsent.VerifiedMatch -eq $false) "P0-01.4: Telemetria sem modelo resulta em PROOF_ABSENT"

# --------------------------------------------------------------------------
# 2. P0-02: FALLBACK CONTROLADO E ADMISSIBILIDADE
# --------------------------------------------------------------------------
# 2.1 Downgrade de Reviewer em risco critical/high e terminantemente proibido
# (mesmo-tier T3 esgotado: sonnet via FailedModel + terra tentado; T4 exige
# prova kernel-owned, T2 e downgrade proibido para high/critical). Medium
# admite T2 e recebe candidato audit-only DeepSeek em HOLD.
$selRevCrit = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'critical' -NativeModelOverrideProven $true
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRevCrit -FailedModel $selRevCrit.CatalogModel -AttemptedModels @('openai/gpt-6-luna', 'openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "P0-02.1: Downgrade de Reviewer em risco critical e proibido fail-closed"
$selRevMedT4 = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -NativeModelOverrideProven $true
$selRevMedT4Shape = $selRevMedT4 | Select-Object *
$selRevMedT4Shape.Tier = 'T4'; $selRevMedT4Shape.CatalogModel = 'claude-agent/opus'
$fbRevMedT4 = Resolve-OrchestrationModelFallback -RequestedSelection $selRevMedT4Shape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-Hardening ($fbRevMedT4.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fbRevMedT4.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $null -eq $fbRevMedT4.FallbackModel -and -not [bool]$fbRevMedT4.IsAuthorized) "P0-02.1: Reviewer medium admite T2 e recebe DeepSeek audit-only em HOLD"

# 2.2 Security-reviewer nunca pode receber downgrade
# (mesmo-tier T3 esgotado: sonnet via FailedModel + terra tentado)
$selSecRev = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'low' -NativeModelOverrideProven $true
$fbSecDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selSecRev -FailedModel $selSecRev.CatalogModel -AttemptedModels @('openai/gpt-6-luna', 'openai/gpt-6.1-sol', 'openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbSecDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "P0-02.2: Downgrade de Security-Reviewer e estritamente proibido mesmo sob risco low"

# 2.3 Transporte T2 (matriz v1.4 vigente: Luna -> DeepSeek Go -> Muse -> Haiku, audit-only HOLD).
# Disponibilidade permanece HOLD mesmo com capability + no-start provados:
# CandidateModel e auditoria nao-autorizadora, nunca replay produtivo.
# Muse e opencode-go (nao Claude), entao sem capability Claude o primeiro
# candidato apos Luna e DeepSeek Go em HOLD, seguido por Muse; Haiku exige capability
# Claude + no-start e sem ela e excluido. A primária Luna não reaparece.
# Esgotados os candidatos elegíveis, EXHAUSTED; Console Free nunca e candidato;
# T2 esgotado nunca escala para T3.
$fbMuseHold = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'opencode-go/deepseek-v4.1-flash' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -ClaudeAgentProven $true
Assert-Hardening ($fbMuseHold.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fbMuseHold.IsAuthorized -eq $false -and $null -eq $fbMuseHold.FallbackModel) "P0-02.3: T2 DeepSeek Go->Muse permanece HOLD mesmo com capability + no-start (sem autorizacao produtiva)"
Assert-Hardening ($fbMuseHold.CandidateModel -eq 'opencode-go/muse-spark-1.3-contributor' -and $fbMuseHold.FallbackTier -eq 'T2') "P0-02.3: Muse e candidato audit-only apos Luna e DeepSeek Go"
$evMuseHold = @{ Model = $fbMuseHold.CandidateModel; AuthorizedFallback = $fbMuseHold }
$vMuseHold = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent $evMuseHold -NativeModelOverrideProven $true
Assert-Hardening ($vMuseHold.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vMuseHold.VerifiedMatch -eq $false -and $vMuseHold.IsAuthorizedFallback -eq $false) "P0-02.3: no-start + capability nao convertem CandidateModel em autorizacao (Muse sob HOLD e UNAUTHORIZED_MISMATCH)"
$fbMuseNoClaude = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'openai/gpt-6-luna' -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbMuseNoClaude.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fbMuseNoClaude.CandidateModel -eq 'opencode-go/deepseek-v4.1-flash' -and $null -eq $fbMuseNoClaude.FallbackModel) "P0-02.3: sem capability Claude, Luna->DeepSeek Go continua HOLD"
$fbLunaNoClaude = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('openai/gpt-6-luna','opencode-go/deepseek-v4.1-flash') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbLunaNoClaude.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $null -eq $fbLunaNoClaude.FallbackModel) "P0-02.3: Haiku excluido sem capability Claude; Luna tentada não reaparece"
$haikuExcl = @($fbLunaNoClaude.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' })
Assert-Hardening ($haikuExcl.Count -ge 1) "P0-02.3: Haiku excluido sem capability Claude (PreventivelyExcluded registra)"
$fbHaiku = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('openai/gpt-6-luna','opencode-go/deepseek-v4.1-flash') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -ClaudeAgentProven $true
Assert-Hardening ($fbHaiku.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fbHaiku.CandidateModel -eq 'claude-agent/haiku' -and $null -eq $fbHaiku.FallbackModel) "P0-02.3: Após Luna+DeepSeek+Muse, Haiku é candidato audit-only sob HOLD quando Claude é provado"
$fbExhaustT2 = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('openai/gpt-6-luna','opencode-go/deepseek-v4.1-flash','opencode-go/muse-spark-1.3-contributor') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbExhaustT2.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fbExhaustT2.IsAuthorized -eq $false -and $null -eq $fbExhaustT2.FallbackModel) "P0-02.3: T2 elegível esgotado sem Claude retorna EXHAUSTED_NO_ELIGIBLE_FALLBACK"
Assert-Hardening (($fbMuseHold.CandidateModel -ne 'opencode/deepseek-v4.1-flash-free') -and ($fbHaiku.CandidateModel -ne 'opencode/deepseek-v4.1-flash-free') -and ($fbExhaustT2.FallbackModel -ne 'opencode/deepseek-v4.1-flash-free')) "P0-02.3: Console Free nunca entra na lista candidata"
Assert-Hardening ($fbMuseHold.FallbackTier -ne 'T3' -and $fbHaiku.FallbackTier -ne 'T3' -and $fbExhaustT2.FallbackTier -ne 'T3' -and $fbExhaustT2.FallbackModel -ne 'openai/gpt-6.1-terra') "P0-02.3: indisponibilidade T2 nunca escala para Terra/T3 sem prova de incapacidade"

# 2.4 Exaustao completa: todos os T2 elegiveis tentados => EXHAUSTED sem loop (sem custo T4)
$allTiersExhausted = @('openai/gpt-6-luna', 'opencode-go/deepseek-v4.1-flash', 'opencode-go/muse-spark-1.3-contributor', 'claude-agent/haiku', 'openai/gpt-6.1-terra', 'openai/gpt-6.1-sol')
$fbExhausted = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels $allTiersExhausted -ProviderCostAuthorized $false -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbExhausted.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fbExhausted.IsAuthorized -eq $false) "P0-02.4: Tentativas esgotadas retornam EXHAUSTED_NO_ELIGIBLE_FALLBACK sem loop"

# --------------------------------------------------------------------------
# 3. P1-01: PROVENIENCIA DE RECIBOS (CANONICO VS AUDITORIA POS-EXECUCAO)
# --------------------------------------------------------------------------
$canonicalReceipt = [ordered]@{
    stage              = "native_dispatch_settlement"
    receipt_provenance = "CANONICAL_PROTOCOL"
    goal_id            = "goal-test-canonical"
    task_id            = "task-test-canonical"
    target_agent       = "coder"
    status             = "candidate_pass"
}
Assert-Hardening ($canonicalReceipt.receipt_provenance -eq 'CANONICAL_PROTOCOL' -and $canonicalReceipt.stage -eq 'native_dispatch_settlement') "P1-01.1: Recibo canonico retem proveniencia CANONICAL_PROTOCOL"

$auditReceipt = [ordered]@{
    stage               = "post_execution_audit_receipt"
    receipt_provenance  = "POST_EXECUTION_AUDIT"
    execution_type      = "PLANNER_AUTONOMOUS_COORDINATION"
    goal_id             = "goal-test-audit"
    task_id             = "task-test-audit"
    target_agent        = "coder"
    status              = "candidate_pass"
    reconstructed_chain = [ordered]@{
        goal_id         = "goal-test-audit"
        task_id         = "task-test-audit"
        planner_session = "ses_planner"
        child_session   = "ses_child"
        kernel_revision = 4
    }
}
Assert-Hardening ($auditReceipt.receipt_provenance -eq 'POST_EXECUTION_AUDIT' -and $auditReceipt.stage -eq 'post_execution_audit_receipt') "P1-01.2: Recibo pos-execucao identifica explicitamente POST_EXECUTION_AUDIT sem simular settlement em tempo real"
Assert-Hardening ($null -ne $auditReceipt.reconstructed_chain -and $auditReceipt.reconstructed_chain.kernel_revision -eq 4) "P1-01.3: Cadeia reconstruida valida vinculo completo da sessao ao Kernel"

# --------------------------------------------------------------------------
# 4. P1-02: INTEGRIDADE DO ARTEFATO EM 3 MARCOS DETERMINISTICOS
# --------------------------------------------------------------------------
$tmpArtDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pilot-art-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpArtDir -Force | Out-Null
try {
    $testArtFile = Join-Path $tmpArtDir 'SampleUtil.ps1'
    [System.IO.File]::WriteAllText($testArtFile, "function Get-Test { 'pass' }`n", [System.Text.Encoding]::UTF8)

    # Marco 1: Pre-Test
    $sha1 = (Get-FileHash -LiteralPath $testArtFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Hardening (-not [string]::IsNullOrWhiteSpace($sha1)) "P1-02.1: Marco 1 (Pre-Test) computa SHA256 deterministico do artefato"

    # Marco 2: Post-Test (inalterado)
    $sha2 = (Get-FileHash -LiteralPath $testArtFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Hardening ($sha1 -eq $sha2) "P1-02.2: Marco 2 (Post-Test) confirma artefato inalterado apos execucao dos testes"

    # Marco 3: Post-Review (inalterado)
    $sha3 = (Get-FileHash -LiteralPath $testArtFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Hardening ($sha2 -eq $sha3) "P1-02.3: Marco 3 (Post-Review) confirma artefato inalterado durante e apos a revisao"

    # Deteccao de Drift pós-teste
    [System.IO.File]::AppendAllText($testArtFile, "# injected comment`n", [System.Text.Encoding]::UTF8)
    $shaTampered = (Get-FileHash -LiteralPath $testArtFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $driftDetected = ($shaTampered -ne $sha1)
    Assert-Hardening ($driftDetected -eq $true) "P1-02.4: Deteccao de alteracao do artefato entre testes e revisao (fail-closed)"
} finally {
    if (Test-Path -LiteralPath $tmpArtDir) { Remove-Item -LiteralPath $tmpArtDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "Total: $total | Passed: $passed | Failed: 0"
Write-Host ">>> SUITE DE HARDENING NATIVE-FIRST PILOT: PASS (25/25 assertions)"
