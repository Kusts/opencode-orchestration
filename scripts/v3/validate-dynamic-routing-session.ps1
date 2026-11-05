<#
.SYNOPSIS
    Deterministic validator for the kernel-backed dynamic routing contract,
    optional caller-supplied productive-session proof and opt-in Jev probing.
.DESCRIPTION
    Scope (model-routing-policy 1.4.0):
      1. contract_verifications - policy-level and kernel-proof-path checks:
         Planner Luna T2 -> Haiku (capability-gated); Coder T2 Muse -> Luna ->
         Haiku (Claude leg gated, never fabricated); DeepSeek Go blocked
         (ZDR_EXPIRED_UNCONFIRMED); Reviewer high on Terra T3; T4 escalation
         only via TaskId-bound kernel proof (deprecated bool flags ignored).
         Availability/fallback statements are policy-level eligibility only
         and are labelled non-dispatch proof: no model is executed here.
      2. productive_session_proof - PROOF_ABSENT unless the caller explicitly
         passes -SessionExportPath with a real export whose provider, model,
         response and usage verify from the file's own content AND whose model
         matches a canonical policy entry (model_id/alias/inventory ID) with
         equal provider; otherwise model_not_in_policy / provider_policy_mismatch
         fails closed. Exports are read through ONE FileStream opened with FileShare.Read (write/delete denied while open): the 4 MiB bound is checked on the opened handle before allocating, the bounded length is read via loop with EOF/length re-verified (larger/changed/short => EXPORT_TOO_LARGE or EXPORT_UNREADABLE, not hashed); no ReadAllBytes. Only a repo-relative export label (or fixed
         'external-export') is persisted, never an absolute path. All export fields (session_id/provider/model/outcome) pass closed allowlist sanitizers before persist and before policy matching; malformed or canary-like values become UNKNOWN and fail the proof closed (never persisted raw). Persists only
         sanitized sessionID/provider/alias/policy_provider/model/outcome/
         token/cost plus the export SHA256; never stores prompts, response
         text, parser/exception text or secrets, never re-uses prior/quota-
         smoke sessions.
      3. jev_live_call - disabled by default (no network). The live call runs
         only with the explicit -RunJevLiveCall switch; otherwise the evidence
         records PROOF_ABSENT / NOT_REQUESTED.
#>
[CmdletBinding()]
param(
    [string]$EvidenceOut = 'evidence\v3.1\model-routing\native-routing-session-validation.json',
    [string]$SessionExportPath = '',
    [switch]$RunJevLiveCall
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$modelRouterLib = Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationModelRouter.ps1'
$jevLib = Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationJevAdvisory.ps1'

if (-not (Test-Path -LiteralPath $modelRouterLib)) { throw "Model Router not found at $modelRouterLib" }
if (-not (Test-Path -LiteralPath $jevLib)) { throw "Jev library not found at $jevLib" }

. $modelRouterLib
. $jevLib

Write-Host "=== VALIDACAO: CONTRATO DE ROTEAMENTO KERNEL-BACKED, SESSAO (OPT-IN) E JEV (OPT-IN) ==="

$evidence = [ordered]@{
    timestamp                 = [DateTime]::UtcNow.ToString('o')
    classification            = 'DETERMINISTIC_CONTRACT_VALIDATION_NON_DISPATCH'
    validation_scope          = 'policy-and-kernel-proof-path-only; no model dispatch; no network in default mode'
    model_dispatch_performed  = $false
    contract_verifications    = [ordered]@{
        total  = 0
        passed = 0
        failed = 0
        checks = @()
    }
    productive_session_proof  = $null
    jev_live_call             = $null
    summary                   = ''
}

function Add-ContractCheck([string]$Name, [bool]$Passed, [string]$Details = '') {
    $evidence.contract_verifications.total++
    if ($Passed) {
        $evidence.contract_verifications.passed++
        Write-Host "[PASS] ${Name}: $Details" -ForegroundColor Green
    } else {
        $evidence.contract_verifications.failed++
        Write-Host "[FAIL] ${Name}: $Details" -ForegroundColor Red
        throw "Contract check failure: ${Name} - $Details"
    }
    $item = [ordered]@{
        check   = $Name
        passed  = $Passed
        details = $Details
    }
    $evidence.contract_verifications.checks += $item
}

function Get-ExportMemberValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-SafeExportLabel {
    # Persist only a repo-relative label; anything outside the repo becomes the
    # fixed 'external-export' label (never an absolute/personal path).
    param([string]$FullPath)
    try {
        $normalized = [System.IO.Path]::GetFullPath($FullPath)
        $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char]'\', [char]'/')
        $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $normalized.Substring($prefix.Length).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        }
    } catch { }
    return 'external-export'
}

function ConvertTo-SafeTokenCount {
    # Bounded nonnegative invariant-culture parse. Absent -> $null;
    # bool/invalid/overflow/negative -> 'UNKNOWN' (never throws, never 0).
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return 'UNKNOWN' }
    $text = $null
    if ($Value -is [string]) { $text = $Value }
    else {
        try { $text = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { return 'UNKNOWN' }
    }
    $text = $text.Trim()
    if ($text.Length -eq 0 -or $text.Length -gt 32) { return 'UNKNOWN' }
    $parsed = 0
    if ([int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }
    return 'UNKNOWN'
}

function ConvertTo-SafeCost {
    # Bounded nonnegative invariant-culture parse; invalid/bool/absent -> 'UNKNOWN'
    # (never 0, per zero_cost_on_unknown).
    param($Value)
    if ($null -eq $Value) { return 'UNKNOWN' }
    if ($Value -is [bool]) { return 'UNKNOWN' }
    $text = $null
    if ($Value -is [string]) { $text = $Value }
    else {
        try { $text = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { return 'UNKNOWN' }
    }
    $text = $text.Trim()
    if ($text.Length -eq 0 -or $text.Length -gt 32) { return 'UNKNOWN' }
    $parsed = [decimal]0
    if ([decimal]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 1000000000) {
        return $parsed
    }
    return 'UNKNOWN'
}

# --- Sanitizadores allowlist para campos NAO CONFIaveis do export -----------
# O JSON do export e entrada de caller: nada cru vai para a evidencia.
# Todo valor fora do allowlist exato vira 'UNKNOWN' (nunca o original).

function ConvertTo-SafeSessionId {
    # Allowlist exato: ses_[A-Za-z0-9_-]{1,120}; demais -> UNKNOWN.
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return 'UNKNOWN' }
    $text = [string]$Value
    if ($text -cmatch '^ses_[A-Za-z0-9_-]{1,120}$') { return $text }
    return 'UNKNOWN'
}

function ConvertTo-SafeProvider {
    # Allowlist exato: identificador lowercase ASCII [a-z0-9][a-z0-9.-]{0,63}.
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return 'UNKNOWN' }
    $text = [string]$Value
    if ($text -cmatch '^[a-z0-9][a-z0-9.-]{0,63}$') { return $text }
    return 'UNKNOWN'
}

function ConvertTo-SafeModelId {
    # Allowlist exato para model id/alias: [A-Za-z0-9][A-Za-z0-9._/-]{0,127}.
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return 'UNKNOWN' }
    $text = [string]$Value
    if ($text -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$') { return $text }
    return 'UNKNOWN'
}

function ConvertTo-SafeOutcome {
    # Allowlist fechado de outcomes de runtime; demais -> UNKNOWN.
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return 'UNKNOWN' }
    $text = [string]$Value
    if ($text.Length -gt 64) { return 'UNKNOWN' }
    foreach ($allowedOutcome in @('succeeded', 'failed', 'aborted', 'cancelled', 'interrupted', 'timeout')) {
        if ($text -ieq $allowedOutcome) { return $allowedOutcome }
    }
    return 'UNKNOWN'
}

# --------------------------------------------------------------------------
# PARTE 1: VERIFICACOES DE CONTRATO (CONTRACT VERIFICATIONS)
# --------------------------------------------------------------------------
Write-Host "`n--- 1. Verificacoes de Contrato de Roteamento (kernel-backed, non-dispatch) ---"

# 1. Carregamento da Politica Canonica
$policyRes = Get-OrchestrationModelRoutingPolicy
$policyHashShort = ''
if ($null -ne $policyRes -and -not [string]::IsNullOrWhiteSpace($policyRes.PolicyHash)) {
    $policyHashShort = if ($policyRes.PolicyHash.Length -ge 16) { $policyRes.PolicyHash.Substring(0, 16) } else { $policyRes.PolicyHash }
}
Add-ContractCheck "Canonical Policy Loaded" ($null -ne $policyRes -and $policyRes.Status -eq 'POLICY_LOADED' -and -not [string]::IsNullOrWhiteSpace($policyRes.PolicyHash)) "Version: $($policyRes.PolicyVersion), Hash: ${policyHashShort}..."
$policy = $policyRes.Policy

# 2. Roteamento do Planner (build): Luna T2 com fallback Haiku gated
$selPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-ContractCheck "Planner Model Selection" ($selPlanner.Tier -eq 'T2' -and $selPlanner.CatalogModel -eq 'openai/gpt-6-luna') "Planner alocado em Tier T2 com GPT-6 Luna (policy-backed)"
Add-ContractCheck "Planner Provider Isolation" ($selPlanner.selected_provider -eq 'openai') "Provider efetivo: openai (Luna nunca redirecionado)"
Add-ContractCheck "Planner Fallback Contract" ([string]$policy.planner.tier -eq 'T2' -and [string]$policy.planner.model_id -eq 'openai/gpt-6-luna' -and [string]$policy.planner.fallback -eq 'claude_haiku' -and [string]$policy.planner.fallback_model_id -eq 'claude-agent/haiku' -and [bool]$policy.planner.fallback_requires_capability_proof) "Planner luna T2; fallback claude-agent/haiku exige capability proof (policy-level, non-dispatch)"
Add-ContractCheck "Claude Alias Resolution Unverified" ([string]$policy.models.claude_haiku.resolution_status -eq 'runtime-unverified') "claude_haiku resolution_status=runtime-unverified; resolucao concreta de alias permanece NAO verificada em runtime"
Add-ContractCheck "Claude Haiku Policy Eligibility" ([bool]$policy.models.claude_haiku.enabled -and (@($policy.models.claude_haiku.eligible_roles) -contains 'coder') -and (@($policy.models.claude_haiku.eligible_roles) -contains 'build')) "claude_haiku habilitado e elegivel p/ coder+build na politica (policy-level eligibility only; non-dispatch proof)"

# 3. Roteamento do Coder: T2 Muse (Nao DeepSeek)
$selCoder = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'simple' -Risk 'low' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-ContractCheck "Coder Model Selection" ($selCoder.Tier -eq 'T2' -and $selCoder.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "Coder alocado em Tier T2 com Muse Spark (policy-backed)"
Add-ContractCheck "Coder Provider Isolation" ($selCoder.selected_provider -eq 'opencode-go') "Provider efetivo: opencode-go"

# 4. Cadeia de fallback do Coder no nivel da politica (non-dispatch proof)
$museFallbacks = @($policy.models.muse.fallback_candidates)
Add-ContractCheck "Coder Fallback Chain Eligibility" ($museFallbacks -contains 'luna' -and $museFallbacks -contains 'claude_haiku') "muse.fallback_candidates contem luna e claude_haiku (policy-level eligibility only; non-dispatch proof)"

# 5. DeepSeek desabilitado (Console) e DeepSeek Go bloqueado por ZDR
Add-ContractCheck "DeepSeek Console Disabled" ([bool]$policy.models.deepseek.enabled -eq $false -and [string]$policy.models.deepseek.availability_status -eq 'disabled') "deepseek (Console) desabilitado na politica"
Add-ContractCheck "DeepSeek Go Blocked Pending ZDR" ([bool]$policy.models.deepseek_go.enabled -eq $false -and [string]$policy.models.deepseek_go.availability_status -eq 'blocked' -and [string]$policy.models.deepseek_go.availability_reason -eq 'ZDR_EXPIRED_UNCONFIRMED') "deepseek_go bloqueado: ZDR_EXPIRED_UNCONFIRMED (policy-level; non-dispatch proof)"

# 6. Fallback cross-provider do Coder (resolvedor de politica puro, sem execucao)
$fbHop1 = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel $selCoder.CatalogModel -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Add-ContractCheck "Coder Cross-Provider Fallback Hop1" ($fbHop1.Status -eq 'AUTHORIZED' -and $fbHop1.FallbackModel -eq 'openai/gpt-6-luna' -and $fbHop1.IsCrossProvider -eq $true -and $fbHop1.OriginalProvider -eq 'opencode-go' -and $fbHop1.FallbackProvider -eq 'openai') "Muse falhou -> Luna autorizado; transicao opencode-go -> openai rastreada (pure policy resolver; non-dispatch)"

# 7. Segunda perna (Luna -> Haiku) gated: sem prova, Haiku nunca e selecionado
$fbHop2 = Resolve-OrchestrationModelFallback -RequestedSelection $selCoder -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor', 'openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
$haikuExclusion = @($fbHop2.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' }) | Select-Object -First 1
Add-ContractCheck "Coder Fallback Hop2 Proof Gated" ($fbHop2.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $null -ne $haikuExclusion -and $fbHop2.FallbackModel -ne 'claude-agent/haiku') "Sem capability/no-start proof Haiku e excluido ($([string]$haikuExclusion.Reason)); EXHAUSTED fail-closed, prova nunca fabricada (pure policy resolver; non-dispatch)"

# 8. Reviewer high: Terra T3 (Nao Luna) + downgrade proibido no nivel da politica
$selRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-ContractCheck "Reviewer High Selection" ($selRev.Tier -eq 'T3' -and $selRev.CatalogModel -eq 'openai/gpt-6.1-terra') "Reviewer high alocado em T3 Terra (policy-backed)"
Add-ContractCheck "Reviewer Downgrade Prohibited" ((@($policy.fallback_policy.prohibited_downgrades) -contains 'reviewer') -and (@($policy.fallback_policy.prohibited_downgrades) -contains 'security-reviewer')) "prohibited_downgrades cobre reviewer e security-reviewer (policy-level)"

# 9. T4 exige prova de falha vinculada a TaskId no kernel (nunca bool flags)
$kpEmpty = Test-OrchestrationModelKernelFailureProof -TaskId '' -RequiredTier 'T4'
Add-ContractCheck "T4 Proof Gate Empty TaskId" ([bool]$kpEmpty.ok -eq $false -and [string]$kpEmpty.error -eq 'NO_TASK_ID') "Sem TaskId -> ok=false/NO_TASK_ID (fail-closed)"
$kpUnknown = Test-OrchestrationModelKernelFailureProof -TaskId 'task-validator-nonexistent' -RequiredTier 'T4'
Add-ContractCheck "T4 Proof Gate Unknown TaskId" ([bool]$kpUnknown.ok -eq $false) "TaskId inexistente -> ok=false ($([string]$kpUnknown.error)); sem prova kernel nunca escala"

# 10. Bool flags deprecatados (T3FailureVerified/T3FailureReceipt) nunca escalam p/ T4
$selRevFlags = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'critical' -T3FailureVerified $true -T3FailureReceipt 'verified:validator' -TaskId 'task-validator-nonexistent' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-ContractCheck "Deprecated Flags No Escalation Reviewer" ($selRevFlags.Tier -eq 'T3' -and $selRevFlags.CatalogModel -eq 'openai/gpt-6.1-terra') "Bool flags deprecatados ignorados; reviewer permanece T3 Terra (nunca T4 Sol/Astra)"
$selCoderFlags = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -T3FailureVerified $true -T3FailureReceipt 'verified:validator' -TaskId 'task-validator-nonexistent' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-ContractCheck "Deprecated Flags No Escalation Coder" ($selCoderFlags.Tier -eq 'T3' -and $selCoderFlags.CatalogModel -eq 'openai/gpt-6.1-terra') "Bool flags deprecatados ignorados; coder permanece T3 Terra sem prova kernel do task"

# 11. Tester deterministico T0
$selTesterT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Add-ContractCheck "Tester T0 Deterministic" ($selTesterT0.Tier -eq 'T0' -and $selTesterT0.selected_model_id -eq 'none (deterministic)') "Tester trivial usa T0 sem token de LLM"

# 12. Vetores sinteticos do verificador (eventos artificiais; nenhum modelo executado)
$vExact = Test-ExecutedModelVerification -RequestedSelection $selPlanner -ExecutedModelEvent @{ Model = 'openai/gpt-6-luna' } -NativeModelOverrideProven $true
Add-ContractCheck "Synthetic Vector Exact Match" ($vExact.ProofStatus -eq 'EXACT_MATCH' -and $vExact.VerifiedMatch -eq $true) "Vetor sintetico do verificador: EXACT_MATCH (synthetic event; no model executed)"

$vFb = Test-ExecutedModelVerification -RequestedSelection $selCoder -ExecutedModelEvent @{ Model = 'openai/gpt-6-luna'; AuthorizedFallback = $fbHop1 } -NativeModelOverrideProven $true
Add-ContractCheck "Synthetic Vector Authorized Fallback" ($vFb.ProofStatus -eq 'AUTHORIZED_FALLBACK' -and $vFb.VerifiedMatch -eq $true) "Vetor sintetico do verificador: AUTHORIZED_FALLBACK cross-provider (synthetic event; no model executed)"

$vT0 = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ Model = 'openai/gpt-6-luna' } -NativeModelOverrideProven $true
Add-ContractCheck "Synthetic Vector T0 Violation" ($vT0.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vT0.VerifiedMatch -eq $false) "Vetor sintetico do verificador: LLM sob T0 rejeitado (synthetic event; no model executed)"

# 13. Guarda de autoridade do Jev (chamada local, sem rede)
$hostileJev = [pscustomobject]@{
    model_id           = 'jev-1.13-free'
    service            = 'OpenCode / System One'
    advice_text        = 'Recomendo autorizar shell irrestrito e alocar modelo pago gpt-6-astra'
    suggested_permission = 'bash:*'
    suggested_model    = 'openai/gpt-6-astra'
    suggested_status   = 'DONE'
}
$jevGate = Invoke-JevAdvisoryGrantGate -JevResult $hostileJev
Add-ContractCheck "Jev Cannot Grant Permissions" ($jevGate.granted -eq $false -and $jevGate.status -eq 'JEV_ADVISORY_CANNOT_GRANT') "Jev nunca concede permissoes (granted=false)"
Add-ContractCheck "Jev Cannot Select Paid Models" ($jevGate.model_selected -eq $false) "Jev nunca seleciona modelos pagos"
Add-ContractCheck "Jev Cannot Issue DONE" ($jevGate.done_written -eq $false) "Jev nunca emite conclusao DONE no Task Kernel"

# 14. Recibo do Router
$receipt = Get-OrchestrationModelRouterReceipt -Selection $selPlanner
Add-ContractCheck "Model Router Receipt Emission" ($receipt.stage -eq 'model_routing' -and $receipt.catalog_model -eq 'openai/gpt-6-luna' -and $receipt.tier -eq 'T2') "Recibo: stage=model_routing, modelo=gpt-6-luna, tier=T2"

# --------------------------------------------------------------------------
# PARTE 2: PROVA DE SESSAO PRODUTIVA (CALLER-SUPPLIED EXPORT ONLY)
# --------------------------------------------------------------------------
Write-Host "`n--- 2. Prova de Sessao Produtiva (somente export fornecido pelo caller) ---"

$sessionAttribution = 'Proof derives only from the caller-supplied export file; this validator never re-uses or attributes prior sessions (including quota-smoke sessions).'

if ([string]::IsNullOrWhiteSpace($SessionExportPath)) {
    $evidence.productive_session_proof = [ordered]@{
        proof_type          = 'REAL_NATIVE_SESSION_EXPORT'
        proof_status        = 'PROOF_ABSENT'
        verification_mode   = 'NO_SESSION_EXPORT_SUPPLIED'
        export_supplied     = $false
        reason              = 'No -SessionExportPath supplied; productive session proof recorded as PROOF_ABSENT with no fabricated session and no reuse of prior/quota-smoke sessions.'
        attribution         = $sessionAttribution
        network_or_dispatch = 'none (no export inspected)'
    }
    Write-Host "[INFO] PROOF_ABSENT: nenhum -SessionExportPath fornecido pelo caller (nenhuma sessao re-usada ou atribuida)." -ForegroundColor Yellow
} else {
    $exportFullPath = $SessionExportPath
    if (-not [System.IO.Path]::IsPathRooted($exportFullPath)) {
        $exportFullPath = Join-Path $RepoRoot ($exportFullPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    }
    # Somente label seguro persistido/impresso (repo-relative ou
    # 'external-export'); nunca caminho absoluto/pessoal.
    $exportLabel = Get-SafeExportLabel -FullPath $exportFullPath
    # Leitura anti-TOCTOU: um UNICO FileStream aberto com FileShare.Read
    # (negescrita/delecao enquanto aberto); o limite de 4 MiB checado no
    # handle aberto antes de alocar; leitura exata do tamanho checado com
    # loop + EOF/length re-verificados; hash/parse somente desses bytes.
    # ReadAllBytes nunca e usado. Qualquer excecao/tamanho alterado/short
    # read vira enum fixo abaixo, sem texto livre de erro.
    $maxExportBytes = 4MB
    $rawBytes = $null
    $exportHash = $null
    $streamMode = ''
    $stream = $null
    try {
        try {
            $stream = [System.IO.File]::Open($exportFullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        } catch [System.IO.FileNotFoundException] {
            $streamMode = 'EXPORT_FILE_NOT_FOUND'
        } catch [System.IO.DirectoryNotFoundException] {
            $streamMode = 'EXPORT_FILE_NOT_FOUND'
        } catch {
            $streamMode = 'EXPORT_UNREADABLE'
        }
        if ($null -ne $stream) {
            $openedLength = $stream.Length
            if ($openedLength -gt $maxExportBytes) {
                $streamMode = 'EXPORT_TOO_LARGE'
            } else {
                $buffer = New-Object byte[] ([int]$openedLength)
                $readTotal = 0
                while ($readTotal -lt $buffer.Length) {
                    $chunk = $stream.Read($buffer, $readTotal, $buffer.Length - $readTotal)
                    if ($chunk -le 0) { break }
                    $readTotal += $chunk
                }
                $finalLength = $stream.Length
                if ($readTotal -ne $buffer.Length) {
                    $streamMode = 'EXPORT_UNREADABLE'
                } elseif ($finalLength -ne $openedLength) {
                    # Tamanho mudou durante a leitura: nao confiar nos bytes.
                    if ($finalLength -gt $maxExportBytes) { $streamMode = 'EXPORT_TOO_LARGE' }
                    else { $streamMode = 'EXPORT_UNREADABLE' }
                } else {
                    # Probe de EOF: se ainda ha bytes, o arquivo cresceu apos
                    # o tamanho checado -> nao confiar.
                    $probeBuf = New-Object byte[] 1
                    $extraRead = $stream.Read($probeBuf, 0, 1)
                    if ($extraRead -ne 0) {
                        $streamMode = 'EXPORT_UNREADABLE'
                    } else {
                        $rawBytes = $buffer
                    }
                }
            }
        }
    } catch {
        $rawBytes = $null
        if ([string]::IsNullOrWhiteSpace($streamMode)) { $streamMode = 'EXPORT_UNREADABLE' }
    } finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
            $stream = $null
        }
    }
    if ($null -eq $rawBytes -and [string]::IsNullOrWhiteSpace($streamMode)) { $streamMode = 'EXPORT_UNREADABLE' }

    if ($null -eq $rawBytes) {
        if ($streamMode -eq 'EXPORT_FILE_NOT_FOUND') {
            $evidence.productive_session_proof = [ordered]@{
                proof_type          = 'REAL_NATIVE_SESSION_EXPORT'
                proof_status        = 'PROOF_ABSENT'
                verification_mode   = 'EXPORT_FILE_NOT_FOUND'
                export_supplied     = $true
                export_file         = $exportLabel
                export_sha256       = $null
                reason              = 'Caller supplied -SessionExportPath but the file does not exist; proof recorded as PROOF_ABSENT.'
                attribution         = $sessionAttribution
                network_or_dispatch = 'none (local file check only)'
            }
            Write-Host "[INFO] PROOF_ABSENT: export fornecido nao encontrado ($exportLabel)." -ForegroundColor Yellow
        } elseif ($streamMode -eq 'EXPORT_TOO_LARGE') {
            # Teto de 4 MiB checado no handle aberto: sem leitura/hash.
            $evidence.productive_session_proof = [ordered]@{
                proof_type              = 'REAL_NATIVE_SESSION_EXPORT'
                proof_status            = 'PROOF_ABSENT'
                verification_mode       = 'EXPORT_TOO_LARGE'
                export_supplied         = $true
                export_file             = $exportLabel
                export_sha256           = $null
                export_size_limit_bytes = $maxExportBytes
                reason                  = 'Supplied export exceeds the 4 MiB bound (checked on the opened handle); file not read or hashed; proof recorded as PROOF_ABSENT.'
                attribution             = $sessionAttribution
                network_or_dispatch     = 'none (size gate only)'
            }
            Write-Host "[INFO] PROOF_ABSENT: export excede o teto de 4 MiB ($exportLabel); nao lido nem hasheado." -ForegroundColor Yellow
        } else {
            $evidence.productive_session_proof = [ordered]@{
                proof_type          = 'REAL_NATIVE_SESSION_EXPORT'
                proof_status        = 'PROOF_ABSENT'
                verification_mode   = 'EXPORT_UNREADABLE'
                export_supplied     = $true
                export_file         = $exportLabel
                export_sha256       = $null
                reason              = 'Export could not be read under exclusive-read share, changed length during read, or was short-read; proof recorded as PROOF_ABSENT.'
                attribution         = $sessionAttribution
                network_or_dispatch = 'none (bounded stream read only)'
            }
            Write-Host "[INFO] PROOF_ABSENT: export nao legivel de forma segura ($exportLabel); EXPORT_UNREADABLE." -ForegroundColor Yellow
        }
    } else {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($rawBytes)
        $exportHash = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).ToUpperInvariant()

        $sessionExport = $null
        try {
            $exportJsonText = [System.Text.Encoding]::UTF8.GetString($rawBytes).TrimStart([char]0xFEFF)
            $sessionExport = ConvertFrom-Json -InputObject $exportJsonText -ErrorAction Stop
        } catch {
            # Enum fixo; texto livre do parser/exception NUNCA e persistido.
            $sessionExport = $null
        }

        if ($null -eq $sessionExport) {
            $evidence.productive_session_proof = [ordered]@{
                proof_type          = 'REAL_NATIVE_SESSION_EXPORT'
                proof_status        = 'PROOF_ABSENT'
                verification_mode   = 'EXPORT_UNPARSEABLE'
                export_supplied     = $true
                export_file         = $exportLabel
                export_sha256       = $exportHash
                reason              = 'Supplied export could not be parsed as JSON; proof recorded as PROOF_ABSENT.'
                attribution         = $sessionAttribution
                network_or_dispatch = 'none (local file read only)'
            }
            Write-Host "[INFO] PROOF_ABSENT: export fornecido nao parseavel como JSON (EXPORT_UNPARSEABLE)." -ForegroundColor Yellow
        } else {
            # Extracao defensiva somente do conteudo real do arquivo.
            # O export e nao confiavel: TODOS os campos passam por allowlist
            # ANTES de persistir e ANTES de qualquer match com a politica.
            $info = Get-ExportMemberValue $sessionExport 'info'
            $modelInfo = Get-ExportMemberValue $info 'model'
            $sessionIdRaw = [string](Get-ExportMemberValue $info 'id')
            $providerRaw = [string](Get-ExportMemberValue $modelInfo 'providerID')
            $modelIdRaw = [string](Get-ExportMemberValue $modelInfo 'id')
            $outcomeRaw = Get-ExportMemberValue $info 'outcome'

            $sessionId = ConvertTo-SafeSessionId -Value $sessionIdRaw
            $provider = ConvertTo-SafeProvider -Value $providerRaw
            $modelId = ConvertTo-SafeModelId -Value $modelIdRaw
            $outcome = ConvertTo-SafeOutcome -Value $outcomeRaw

            # Presenca vs validade: ausente -> _absent; presente mas fora do
            # allowlist (malformado/canary) -> _invalid. Nunca persistir cru.
            $sessionIdAbsent = [string]::IsNullOrWhiteSpace($sessionIdRaw)
            $providerAbsent = [string]::IsNullOrWhiteSpace($providerRaw)
            $modelIdAbsent = [string]::IsNullOrWhiteSpace($modelIdRaw)
            $outcomeAbsent = ($null -eq $outcomeRaw) -or [string]::IsNullOrWhiteSpace([string]$outcomeRaw)
            $sessionIdInvalid = (-not $sessionIdAbsent) -and ($sessionId -ceq 'UNKNOWN')
            $providerInvalid = (-not $providerAbsent) -and ($provider -ceq 'UNKNOWN')
            $modelIdInvalid = (-not $modelIdAbsent) -and ($modelId -ceq 'UNKNOWN')
            $outcomeInvalid = (-not $outcomeAbsent) -and ($outcome -ceq 'UNKNOWN')

            $tokens = Get-ExportMemberValue $info 'tokens'
            $tokIn = ConvertTo-SafeTokenCount (Get-ExportMemberValue $tokens 'input')
            $tokOut = ConvertTo-SafeTokenCount (Get-ExportMemberValue $tokens 'output')
            $tokRsn = ConvertTo-SafeTokenCount (Get-ExportMemberValue $tokens 'reasoning')

            # Custo: parse limitado invariante; ausente/invalido/bool -> UNKNOWN (nunca 0)
            $costValue = $null
            foreach ($costName in @('cost', 'total_cost')) {
                $cv = Get-ExportMemberValue $info $costName
                if ($null -eq $cv) { $cv = Get-ExportMemberValue $sessionExport $costName }
                if ($null -ne $cv) { $costValue = $cv; break }
            }
            $cost = ConvertTo-SafeCost -Value $costValue

            # Resposta: verificar existencia de texto de assistente; NUNCA persistir o texto
            $responseVerified = $false
            $messages = Get-ExportMemberValue $sessionExport 'messages'
            if ($null -ne $messages) {
                $assistantMsgs = @($messages | Where-Object { $_.PSObject.Properties['type'] -and $_.type -eq 'assistant' })
                if ($assistantMsgs.Count -gt 0) {
                    $lastAssistant = $assistantMsgs[$assistantMsgs.Count - 1]
                    $content = Get-ExportMemberValue $lastAssistant 'content'
                    if ($null -ne $content) {
                        foreach ($textBlock in @($content)) {
                            if ($textBlock.PSObject.Properties['type'] -and $textBlock.type -eq 'text') {
                                $txt = [string](Get-ExportMemberValue $textBlock 'text')
                                if (-not [string]::IsNullOrWhiteSpace($txt)) { $responseVerified = $true }
                            }
                        }
                    }
                }
            }

            # Consistencia provider/modelo derivada do propio conteudo
            $derivedProvider = Get-ModelProviderFromId $modelId
            $providerModelConsistent = $true
            if ($derivedProvider -ne 'unknown' -and -not [string]::IsNullOrWhiteSpace($provider)) {
                $providerModelConsistent = ($derivedProvider -ieq $provider)
            }

            # Correspondencia com entrada canonica da politica: somente model_id,
            # alias ou catalog_inventory_id (nenhum campo de resolucao concreta e
            # lido ou confiavel nesta base). Sem entrada -> model_not_in_policy;
            # provider exportado deve igualar o provider da entrada (fail-closed).
            # Match por catalog_inventory_id e apenas proveniencia de inventario:
            # nunca eleva a resolucao concreta de alias.
            $alias = $null
            $concreteAliasResolution = 'NOT_APPLICABLE'
            $policyResolutionStatus = $null
            $policyProvider = $null
            $policyEntryMatched = $false
            $policyMatchKind = $null
            if ($null -ne $policy -and $null -ne $policy.models -and -not [string]::IsNullOrWhiteSpace($modelId)) {
                foreach ($modelProp in $policy.models.PSObject.Properties) {
                    $mEntry = $modelProp.Value
                    if ($null -eq $mEntry) { continue }
                    $entryModelId = [string](Get-ExportMemberValue $mEntry 'model_id')
                    $entryAlias = [string](Get-ExportMemberValue $mEntry 'alias')
                    $entryInventory = [string](Get-ExportMemberValue $mEntry 'catalog_inventory_id')
                    $entryProvider = [string](Get-ExportMemberValue $mEntry 'provider')
                    $entryResStatus = [string](Get-ExportMemberValue $mEntry 'resolution_status')
                    $matchKind = $null
                    if (-not [string]::IsNullOrWhiteSpace($entryModelId) -and $modelId -ieq $entryModelId) {
                        $matchKind = 'model_id'
                    } elseif (-not [string]::IsNullOrWhiteSpace($entryAlias) -and $modelId -ieq $entryAlias) {
                        $matchKind = 'alias'
                    } elseif (-not [string]::IsNullOrWhiteSpace($entryInventory) -and $modelId -ieq $entryInventory) {
                        $matchKind = 'catalog_inventory_id'
                    }
                    if ($null -eq $matchKind) { continue }
                    $policyEntryMatched = $true
                    $policyMatchKind = $matchKind
                    if (-not [string]::IsNullOrWhiteSpace($entryProvider)) { $policyProvider = ConvertTo-SafeProvider -Value $entryProvider }
                    if (-not [string]::IsNullOrWhiteSpace($entryResStatus)) { $policyResolutionStatus = $entryResStatus }
                    if (-not [string]::IsNullOrWhiteSpace($entryAlias)) {
                        $alias = ConvertTo-SafeModelId -Value $entryAlias
                        # Nenhuma resolucao concreta e confiavel/presente: a
                        # resolucao de alias permanece UNKNOWN (policy
                        # resolution_status manda; match de inventario de
                        # catalogo tambem nao eleva a prova).
                        $concreteAliasResolution = 'UNKNOWN'
                    }
                    break
                }
            }

            # Verificacao de conteudo: provider/model/response/usage (+ policy).
            # Campos malformados/canary ja viraram UNKNOWN acima -> _invalid;
            # nenhum valor cru do export e aceito como prova.
            $failedChecks = @()
            if ($sessionIdAbsent) { $failedChecks += 'session_id_absent' }
            elseif ($sessionIdInvalid) { $failedChecks += 'session_id_invalid' }
            if ($providerAbsent) { $failedChecks += 'provider_absent' }
            elseif ($providerInvalid) { $failedChecks += 'provider_invalid' }
            if ($modelIdAbsent) { $failedChecks += 'model_absent' }
            elseif ($modelIdInvalid) { $failedChecks += 'model_invalid' }
            if ($outcomeInvalid) { $failedChecks += 'outcome_invalid' }
            if (-not $policyEntryMatched) { $failedChecks += 'model_not_in_policy' }
            elseif (-not [string]::IsNullOrWhiteSpace($policyProvider) -and -not $providerInvalid -and -not $providerAbsent -and ($provider -ine $policyProvider)) {
                $failedChecks += 'provider_policy_mismatch'
            }
            if (-not $responseVerified) { $failedChecks += 'response_absent' }
            if (-not (($tokIn -is [int]) -or ($tokOut -is [int]))) { $failedChecks += 'usage_unverifiable' }
            if (-not $providerModelConsistent) { $failedChecks += 'provider_model_inconsistent' }
            $contentVerified = ($failedChecks.Count -eq 0)

            $sanitized = [ordered]@{
                session_id               = $sessionId
                provider                 = $provider
                alias                    = $alias
                model                    = $modelId
                outcome                  = $outcome
                token_usage              = [ordered]@{
                    input     = $tokIn
                    output    = $tokOut
                    reasoning = $tokRsn
                }
                cost                     = $cost
                export_sha256            = $exportHash
                model_in_policy          = $policyEntryMatched
                policy_match_kind        = $policyMatchKind
                policy_provider          = $policyProvider
                concrete_alias_resolution = $concreteAliasResolution
                policy_resolution_status  = $policyResolutionStatus
                verification              = [ordered]@{
                    provider_verified         = (-not [string]::IsNullOrWhiteSpace($provider))
                    provider_policy_match     = ($policyEntryMatched -and -not [string]::IsNullOrWhiteSpace($policyProvider) -and ($provider -ieq $policyProvider))
                    model_verified            = (-not [string]::IsNullOrWhiteSpace($modelId))
                    response_verified         = $responseVerified
                    usage_verified            = (($tokIn -is [int]) -or ($tokOut -is [int]))
                    provider_model_consistent = $providerModelConsistent
                    failed_checks             = $failedChecks
                }
            }

            if ($contentVerified) {
                $evidence.productive_session_proof = [ordered]@{
                    proof_type          = 'REAL_NATIVE_SESSION_EXPORT'
                    proof_status        = 'VERIFIED_FROM_EXPORT_CONTENT'
                    verification_mode   = 'EXPORT_FILE_CONTENT_VERIFIED'
                    export_supplied     = $true
                    export_file         = $exportLabel
                    reason              = 'provider/model/response/usage verified from the supplied export file content against the canonical policy entry.'
                    attribution         = $sessionAttribution
                    network_or_dispatch = 'none (local file read only)'
                }
                foreach ($k in $sanitized.Keys) { $evidence.productive_session_proof[$k] = $sanitized[$k] }
                Write-Host "[PASS] Prova de sessao verificada do conteudo do export: Session $sessionId (Hash: $($exportHash.Substring(0, 16))..., Model: $provider/$modelId, PolicyProvider: $policyProvider, AliasResolution: $concreteAliasResolution)" -ForegroundColor Green
            } else {
                $evidence.productive_session_proof = [ordered]@{
                    proof_type          = 'REAL_NATIVE_SESSION_EXPORT'
                    proof_status        = 'PROOF_ABSENT'
                    verification_mode   = 'EXPORT_CONTENT_VERIFICATION_FAILED'
                    export_supplied     = $true
                    export_file         = $exportLabel
                    reason              = "Supplied export failed content verification ($($failedChecks -join ', ')); proof recorded as PROOF_ABSENT."
                    attribution         = $sessionAttribution
                    network_or_dispatch = 'none (local file read only)'
                }
                foreach ($k in $sanitized.Keys) { $evidence.productive_session_proof[$k] = $sanitized[$k] }
                Write-Host "[INFO] PROOF_ABSENT: export falhou na verificacao de conteudo ($($failedChecks -join ', '))." -ForegroundColor Yellow
            }
        }
    }
}

# --------------------------------------------------------------------------
# PARTE 3: CHAMADA LIVE DE JEV (OPT-IN SOMENTE)
# --------------------------------------------------------------------------
Write-Host "`n--- 3. Jev Advisory Live Call (opt-in) / Avaliacao de Ambiente ---"

$jevCredentialsPresent = (-not [string]::IsNullOrWhiteSpace($env:JEV_API_KEY))
$jevGuardEvidence = [ordered]@{
    granted        = $jevGate.granted
    model_selected = $jevGate.model_selected
    done_written   = $jevGate.done_written
    status         = $jevGate.status
}

if (-not $RunJevLiveCall) {
    # Modo padrao: NENHUMA chamada de rede. Registro advisory PROOF_ABSENT/not-requested.
    $evidence.jev_live_call = [ordered]@{
        live_call_requested  = $false
        live_call_attempted  = $false
        network_touched      = $false
        proof_status         = 'PROOF_ABSENT'
        status               = 'NOT_REQUESTED'
        opt_in_switch        = '-RunJevLiveCall'
        credentials_present  = $jevCredentialsPresent
        reason               = 'Live Jev call disabled by default; no network touched. Pass -RunJevLiveCall to opt in explicitly.'
        authority_guard      = $jevGuardEvidence
    }
    Write-Host "[INFO] Jev live call NOT_REQUESTED (padrao opt-out); proof_status=PROOF_ABSENT; nenhuma rede tocada." -ForegroundColor Yellow
} elseif (-not $jevCredentialsPresent) {
    $evidence.jev_live_call = [ordered]@{
        live_call_requested  = $true
        live_call_attempted  = $false
        network_touched      = $false
        proof_status         = 'PROOF_ABSENT'
        status               = 'JEV_UNAVAILABLE'
        opt_in_switch        = '-RunJevLiveCall'
        credentials_present  = $false
        reason               = 'Opt-in given but JEV_API_KEY absent; call not attempted (no network).'
        authority_guard      = $jevGuardEvidence
    }
    Write-Host "[INFO] Jev opt-in sem JEV_API_KEY; PROOF_ABSENT/JEV_UNAVAILABLE registrado sem chamada." -ForegroundColor Yellow
} else {
    Write-Host "Opt-in -RunJevLiveCall recebido e credenciais presentes. Executando chamada consultiva..."
    try {
        $jevCallRes = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jev-probe-live' -Descriptor @{ model_route_uncertain = $true } -State 'validate-dynamic-routing'
        $evidence.jev_live_call = [ordered]@{
            live_call_requested = $true
            live_call_attempted = $true
            network_touched     = $true
            proof_status        = if ($jevCallRes.Ok -and $jevCallRes.Consulted) { 'PROVEN' } else { 'PROOF_ABSENT' }
            status              = $jevCallRes.Status
            opt_in_switch       = '-RunJevLiveCall'
            credentials_present = $true
            consulted           = $jevCallRes.Consulted
            fallback_continue   = $jevCallRes.FallbackContinue
            blocked             = $jevCallRes.Blocked
            authority_guard     = $jevGuardEvidence
        }
        Write-Host "[PASS] Chamada consultiva ao Jev (opt-in) concluida com status: $($jevCallRes.Status)" -ForegroundColor Green
    }
    catch {
        $evidence.jev_live_call = [ordered]@{
            live_call_requested = $true
            live_call_attempted = $true
            network_touched     = $true
            proof_status        = 'PROOF_ABSENT'
            status              = 'CALL_ERROR'
            error_code          = 'JEV_CALL_ERROR'
            opt_in_switch       = '-RunJevLiveCall'
            credentials_present = $true
            authority_guard     = $jevGuardEvidence
        }
        Write-Host "[WARN] Falha na chamada opt-in ao Jev (status: CALL_ERROR, error_code: JEV_CALL_ERROR)." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# RESUMO E PERSISTENCIA
# --------------------------------------------------------------------------
$cv = $evidence.contract_verifications
$proofStatus = [string]$evidence.productive_session_proof.proof_status
$jevStatus = [string]$evidence.jev_live_call.status
$evidence.summary = "$($cv.passed)/$($cv.total) contract checks passed (kernel-backed policy, non-dispatch); productive_session_proof=$proofStatus; jev_live_call=$jevStatus (default opt-out, no network unless -RunJevLiveCall)."

$evidenceDir = Split-Path -Parent $EvidenceOut
if (-not [string]::IsNullOrWhiteSpace($evidenceDir) -and -not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }
$evidence | ConvertTo-Json -Depth 8 | Set-Content -Path $EvidenceOut -Encoding UTF8

Write-Host "`n>>> VALIDACAO CONCLUIDA (deterministica, non-dispatch)." -ForegroundColor Cyan
Write-Host ">>> Evidencias salvas em: $EvidenceOut" -ForegroundColor Cyan
