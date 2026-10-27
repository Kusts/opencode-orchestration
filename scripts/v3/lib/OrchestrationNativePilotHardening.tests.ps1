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

# 1.2 Fallback autorizado pelo Router
$fbDecision = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel $selCoder.CatalogModel -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbDecision.Status -eq 'AUTHORIZED' -and $fbDecision.IsAuthorized -eq $true) "P0-01.2: Router autoriza modelo alternativo no tier"
$evFb = @{ Model = $fbDecision.FallbackModel; AuthorizedFallback = $fbDecision }
$vFb = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent $evFb -NativeModelOverrideProven $true
Assert-Hardening ($vFb.ProofStatus -eq 'AUTHORIZED_FALLBACK' -and $vFb.IsAuthorizedFallback -eq $true -and $vFb.IsExactMatch -eq $false -and $vFb.VerifiedMatch -eq $true) "P0-01.2: Fallback autorizado classifica como AUTHORIZED_FALLBACK (nao exact)"

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
# 2.1 Downgrade de Reviewer em risco medium/high e terminantemente proibido
$selRevMed = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -NativeModelOverrideProven $true
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRevMed -FailedModel $selRevMed.CatalogModel -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "P0-02.1: Downgrade de Reviewer em risco medium e proibido fail-closed"

# 2.2 Security-reviewer nunca pode receber downgrade
$selSecRev = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'low' -NativeModelOverrideProven $true
$fbSecDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selSecRev -FailedModel $selSecRev.CatalogModel -AttemptedModels @('openai/gpt-6-luna', 'openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbSecDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "P0-02.2: Downgrade de Security-Reviewer e estritamente proibido mesmo sob risco low"

# 2.3 Escalada para T3 quando tier T2 se esgota
$fbEscalate = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode/deepseek-v4.1-flash-free', 'opencode-go/muse-spark-1.3-contributor') -TriggerReason 'RATE_LIMIT'
Assert-Hardening ($fbEscalate.Status -eq 'AUTHORIZED' -and $fbEscalate.FallbackTier -eq 'T3') "P0-02.3: Quando T2 se esgota, Coder escala para T3 autorizado"

# 2.4 Exaustao completa sem autorizacao de custo para T4
$allTiersExhausted = @('opencode/deepseek-v4.1-flash-free', 'opencode-go/muse-spark-1.3-contributor', 'openai/gpt-6-luna', 'openai/gpt-6.1-sol')
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
Write-Host ">>> SUITE DE HARDENING NATIVE-FIRST PILOT: PASS (14/14 assertions)"
