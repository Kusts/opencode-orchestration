<#!
.SYNOPSIS
    V3 Stage-2 acceptance SIMULATION (inerte; nunca ativa nada).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar, sem disco/rede) que
    constroi envelopes simulados e deriva veredito WOULD_ACCEPT / WOULD_FALLBACK
    / WOULD_BLOCK e decisao ACTIVATE / HOLD / BLOCKED por categoria.

    A simulacao NAO altera flags, allowlist, policy ou registry: ela apenas
    preenche o parametro opcional -SimulateEnvelope de
    Invoke-CapabilityAcceptance/Get-AcceptanceDecision para UMA categoria por
    vez. Com SimulateEnvelope=$null (default em todo o resto do sistema) o
    comportamento e identico ao Stage 1 ativo.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-Stage2SimTaskMaps {
    <#
    .SYNOPSIS
        Mapas de categoria simulada (matching exato; sem substring).
    #>
    [CmdletBinding()]
    param()
    return @{
        'architecture' = @{ TaskTypes = @{ 'architecture' = 'architecture' }; Domains = @{}; ExpectedAgents = @{ 'architect' = 'architecture' } }
        'debugging'    = @{ TaskTypes = @{ 'debug' = 'debugging'; 'debugging' = 'debugging' }; Domains = @{}; ExpectedAgents = @{ 'debugger' = 'debugging' } }
        'infra'        = @{ TaskTypes = @{}; Domains = @{ 'infra' = 'infra' }; ExpectedAgents = @{ 'infra-engineer' = 'infra' } }
        'ai-agent'     = @{ TaskTypes = @{}; Domains = @{ 'ai' = 'ai-agent' }; ExpectedAgents = @{ 'ai-agent-engineer' = 'ai-agent' } }
        'automation'   = @{ TaskTypes = @{}; Domains = @{ 'automation' = 'automation' }; ExpectedAgents = @{ 'automation-engineer' = 'automation' } }
    }
}

function New-Stage2SimEnvelope {
    <#
    .SYNOPSIS
        Constroi o envelope simulado para UMA categoria (ou $null para Stage 1 puro).
    #>
    [CmdletBinding()]
    param([string]$SimCategory, [string[]]$SimAgents)
    $cat = ([string]$SimCategory).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($cat)) { return $null }
    $maps = Get-Stage2SimTaskMaps
    $taskMap = @{ TaskTypes = @{}; Domains = @{}; ExpectedAgents = @{} }
    if ($maps.ContainsKey($cat)) { $taskMap = $maps[$cat] }
    return @{
        ExtraCategories = @($cat)
        ExtraAgents     = @{ $cat = @($SimAgents) }
        ExtraTaskMap    = $taskMap
    }
}

function Get-Stage2SimVerdict {
    <#
    .SYNOPSIS
        Deriva WOULD_ACCEPT / WOULD_FALLBACK / WOULD_BLOCK de uma decisao simulada.
    #>
    [CmdletBinding()]
    param($Decision)
    try {
        if ($null -eq $Decision) { return 'WOULD_FALLBACK' }
        if ([bool]$Decision.accepted) { return 'WOULD_ACCEPT' }
        if ([bool]$Decision.blocked) { return 'WOULD_BLOCK' }
        if ([string]::IsNullOrWhiteSpace([string]$Decision.selected_agent)) { return 'WOULD_BLOCK' }
        return 'WOULD_FALLBACK'
    }
    catch { return 'WOULD_FALLBACK' }
}

function Get-Stage2CategoryDecision {
    <#
    .SYNOPSIS
        Decisao ACTIVATE / HOLD / BLOCKED por categoria a partir de estatistica adversarial.
    .DESCRIPTION
        Regras (§30):
          MUST (falha => BLOCKED): safety_violations, forbidden_selected,
          policy_bypass, architectural_block.
          Escalation-only (debugging) => HOLD com rationale proprio.
          ACTIVATE: sample>=8, accept_wrong==0, pureza>=0.8, >=4 accepts
          corretos, no maximo 2 ambiguos. Fallbacks corretos em negativos
          NAO penalizam; evidencia positiva fina impede ACTIVATE.
          Caso contrario => HOLD com missing_evidence concreto.
        Confidence HIGH/MEDIUM/LOW/INSUFFICIENT acompanha a decisao.
    #>
    [CmdletBinding()]
    param(
        [string]$Group,
        [int]$Sample = 0,
        [int]$AcceptCorrect = 0,
        [int]$AcceptWrong = 0,
        [int]$Ambiguous = 0,
        [int]$SafetyViolations = 0,
        [int]$ForbiddenSelected = 0,
        [int]$PolicyBypass = 0,
        [bool]$ArchitecturalBlock = $false,
        [string]$ArchitecturalReason = '',
        [bool]$EscalationOnly = $false,
        [double]$StrongConfRate = 0
    )
    $purity = 1.0
    $acceptTotal = $AcceptCorrect + $AcceptWrong
    if ($acceptTotal -gt 0) { $purity = ([double]$AcceptCorrect / [double]$acceptTotal) }
    if ($SafetyViolations -gt 0) {
        return [PSCustomObject]@{ Decision = 'BLOCKED'; Confidence = 'HIGH'; Rationale = 'safety_violations>0 na qualificacao adversarial'; MissingEvidence = '' }
    }
    if ($ForbiddenSelected -gt 0) {
        return [PSCustomObject]@{ Decision = 'BLOCKED'; Confidence = 'HIGH'; Rationale = 'forbidden agent selecionado na simulacao'; MissingEvidence = '' }
    }
    if ($PolicyBypass -gt 0) {
        return [PSCustomObject]@{ Decision = 'BLOCKED'; Confidence = 'HIGH'; Rationale = 'simulacao aceitou tarefa sob hard exclusion (policy bypass)'; MissingEvidence = '' }
    }
    if ($ArchitecturalBlock) {
        $why = [string]$ArchitecturalReason
        if ([string]::IsNullOrWhiteSpace($why)) { $why = 'categoria bloqueada por invariante arquitetural/risco' }
        return [PSCustomObject]@{ Decision = 'BLOCKED'; Confidence = 'HIGH'; Rationale = $why; MissingEvidence = '' }
    }
    if ($EscalationOnly) {
        return [PSCustomObject]@{ Decision = 'HOLD'; Confidence = 'MEDIUM'; Rationale = 'HOLD_AS_ESCALATION_ONLY: debugger somente via escalacao apos tentativa limitada; aceitar como owner primario violaria a filosofia de escalacao'; MissingEvidence = 'definir gatilho formal de escalacao (tentativas/erros) antes de qualquer envelope' }
    }
    if ($Sample -lt 8) {
        return [PSCustomObject]@{ Decision = 'HOLD'; Confidence = 'INSUFFICIENT'; Rationale = ('amostra insuficiente (n=' + $Sample + ' < 8)'); MissingEvidence = ('adicionar ' + (8 - $Sample) + ' casos adversariais com diversidade (positivo/negativo/ambiguo/colisao)') }
    }
    if ($AcceptWrong -gt 0) {
        return [PSCustomObject]@{ Decision = 'HOLD'; Confidence = 'LOW'; Rationale = ('WOULD_ACCEPT com agente fora do esperado/aceitavel: ' + $AcceptWrong); MissingEvidence = 'casos de confusao architect/advisor/skeptic e overlaps de dominio para separar' }
    }
    if ($purity -lt 0.8) {
        return [PSCustomObject]@{ Decision = 'HOLD'; Confidence = 'LOW'; Rationale = ('pureza dos accepts abaixo de 0.8: ' + ([Math]::Round($purity, 4))); MissingEvidence = 'mais casos positivos claros e tuning de confianca' }
    }
    if ($AcceptCorrect -lt 4) {
        return [PSCustomObject]@{ Decision = 'HOLD'; Confidence = 'LOW'; Rationale = ('evidencia positiva fina (accepts corretos=' + $AcceptCorrect + ' < 4); fallbacks corretos em negativos nao contam como positivo'); MissingEvidence = 'mais casos positivos claros onde o Router deve controlar' }
    }
    if ($Ambiguous -gt 2) {
        return [PSCustomObject]@{ Decision = 'HOLD'; Confidence = 'LOW'; Rationale = ('ambiguidade alta (fallbacks com candidato aceitavel=' + $Ambiguous + ' > 2)'); MissingEvidence = 'resolver overhead evitavel (scoring vs expectativa) antes de ativar' }
    }
    $conf = 'MEDIUM'
    if (($Sample -ge 12) -and ($purity -ge 0.9)) { $conf = 'HIGH' }
    elseif ($Sample -lt 10) { $conf = 'LOW' }
    return [PSCustomObject]@{ Decision = 'ACTIVATE'; Confidence = $conf; Rationale = ('n=' + $Sample + ' accepts_corretos=' + $AcceptCorrect + ' pureza=' + ([Math]::Round($purity, 4)) + ' strong_conf_rate=' + ([Math]::Round($StrongConfRate, 4))); MissingEvidence = '' }
}
