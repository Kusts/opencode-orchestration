<#!
.SYNOPSIS
    Etapa 4 REAL - prova com runtime opencode (sem nova maquina de estados).
.DESCRIPTION
    Resolve selecao coder/simple (espera T1/T2 barato), executa
    `opencode run --model <effective> --format json` com prompt trivial que
    so pede JSON {"ping":"pong"} SEM criar arquivos (somente eco), captura
    stdout, extrai modelo observado se o CLI expor (campo model/provider do
    evento json; se o CLI nao expoe, declara PROOF_ABSENT honestamente e NAO
    afirma INTEGRATED). Compara via Test-ExecutedModelVerification, registra
    evidencia JSONL e imprime PROOF_ETAPA4=EXECUTED_VERIFIED:<modelo> ou
    PROOF_ETAPA4=PROOF_ABSENT:<motivo>. Exit 0 nos dois casos honestos;
    exit 1 so em erro de script. Provider indisponivel => PROOF_ABSENT + exit 0.
    PS 5.1, ASCII-only. T4/Astra proibidos aqui (tier barato default).
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = ''
)
$ErrorActionPreference = 'Stop'

function Write-Etapa4Evidence {
    param($Dir, $Record)
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Dir)) { return }
        try {
            if (-not (Test-Path -LiteralPath ([string]$Dir) -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory([string]$Dir)
            }
        } catch { return }
        $line = ($Record | ConvertTo-Json -Compress -Depth 8)
        $target = Join-Path ([string]$Dir) 'etapa4-proof.jsonl'
        [System.IO.File]::AppendAllText($target, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

try {
    . (Join-Path $PSScriptRoot 'lib\OrchestrationModelRouter.ps1')
    . (Join-Path $PSScriptRoot 'lib\OrchestrationModelExecution.ps1')

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
        $EvidenceDir = Join-Path $repoRoot 'evidence\v3\etapa4-proof'
    }
    $stamp = [DateTime]::UtcNow.ToString('o')

    $sel = $null
    try {
        $sel = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'low' -Complexity 'simple' -FailureCount 0 -ProviderCostAuthorized $false -IgnoreUserConfig $true -NativeModelOverrideProven $true
    } catch { $sel = $null }
    if ($null -eq $sel) {
        Write-Host 'PROOF_ETAPA4=PROOF_ABSENT:selection-failed'
        Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'selection-failed' })
        exit 0
    }
    $tier = [string]$sel.Tier
    $effective = [string]$sel.CatalogModel
    if (($tier -ceq 'T4') -or ($effective -match 'astra')) {
        Write-Host 'PROOF_ETAPA4=PROOF_ABSENT:refused-tier-not-allowed-here'
        Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'refused-tier'; tier = $tier; effective_model = $effective })
        exit 0
    }
    if (($tier -cne 'T1') -and ($tier -cne 'T2')) {
        Write-Host ('PROOF_ETAPA4=PROOF_ABSENT:unexpected-tier:' + $tier)
        Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'unexpected-tier'; tier = $tier; effective_model = $effective })
        exit 0
    }

    $hasOpencode = ($null -ne (Get-Command 'opencode' -ErrorAction SilentlyContinue))
    if (-not $hasOpencode) {
        Write-Host 'PROOF_ETAPA4=PROOF_ABSENT:opencode-missing'
        Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'opencode-missing'; tier = $tier; effective_model = $effective })
        exit 0
    }

    $prompt = 'Reply with ONLY this exact JSON and nothing else, do not create any file, do not use any tool: {"ping":"pong"}'

    $raw = $null
    $rc = 0
    try {
        $raw = & opencode run --model $effective --format json $prompt 2>&1
        $rc = [int]$LASTEXITCODE
    } catch {
        $rc = 1
        $raw = @($_.Exception.Message)
    }
    if ($rc -ne 0) {
        Write-Host ('PROOF_ETAPA4=PROOF_ABSENT:provider-unavailable:exit=' + $rc)
        Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'provider-unavailable'; exit_code = $rc; tier = $tier; effective_model = $effective; requested_model = [string]$sel.CatalogModel })
        exit 0
    }

    $textOut = ''
    $observed = ''
    $parsedEvents = 0
    foreach ($line in @($raw)) {
        $s = [string]$line
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        try {
            $evt = $s | ConvertFrom-Json
            $parsedEvents++
            try {
                if ($evt.type -eq 'text') {
                    $t = $null
                    try { $t = [string]$evt.part.text } catch { $t = '' }
                    if (-not [string]::IsNullOrEmpty($t)) { $textOut += $t }
                }
            } catch { }
            $cand = @()
            try { if ($null -ne $evt.model) { $cand += [string]$evt.model } } catch { }
            try { if ($null -ne $evt.Model) { $cand += [string]$evt.Model } } catch { }
            try { if ($null -ne $evt.provider) { $cand += '' } } catch { }
            try { if ($null -ne $evt.message) { if ($null -ne $evt.message.model) { $cand += [string]$evt.message.model } } } catch { }
            try { if ($null -ne $evt.part) { if ($null -ne $evt.part.model) { $cand += [string]$evt.part.model } } } catch { }
            foreach ($c in $cand) {
                if ((-not [string]::IsNullOrWhiteSpace($c)) -and [string]::IsNullOrWhiteSpace($observed)) { $observed = $c.Trim() }
            }
        } catch { }
    }

    $execResult = $null
    if (-not [string]::IsNullOrWhiteSpace($observed)) {
        $evtObj = @{ Model = $observed }
        try { $execResult = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 'etapa4-proof' -Risk 'low' -Complexity 'simple' -FailureCount 0 -ProviderCostAuthorized $false -NativeModelOverrideProven $true -ExecutedModelEvent $evtObj } catch { $execResult = $null }
        $proofStatus = ''
        try { $proofStatus = [string]$execResult.verification.ProofStatus } catch { $proofStatus = '' }
        $textEchoOk = $false
        try { $textEchoOk = [bool]($textOut -match 'pong') } catch { $textEchoOk = $false }
        if (-not $textEchoOk) {
            Write-Host 'PROOF_ETAPA4=PROOF_ABSENT:echo-unverified'
            Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'echo-unverified'; proof_status = $proofStatus; tier = $tier; requested_model = [string]$sel.CatalogModel; effective_model = $effective; observed_model = $observed; parsed_events = $parsedEvents; text_echo_ok = $false })
            exit 0
        }
        if (([string]$execResult.status -ceq 'EXECUTED_VERIFIED') -and (($proofStatus -ceq 'EXACT_MATCH') -or ($proofStatus -ceq 'AUTHORIZED_FALLBACK'))) {
            Write-Host ('PROOF_ETAPA4=EXECUTED_VERIFIED:' + $observed)
            Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'EXECUTED_VERIFIED'; proof_status = $proofStatus; tier = $tier; requested_model = [string]$sel.CatalogModel; effective_model = $effective; observed_model = $observed; parsed_events = $parsedEvents; text_echo_ok = $true })
            exit 0
        }
        Write-Host ('PROOF_ETAPA4=PROOF_ABSENT:' + $proofStatus)
        Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; proof_status = $proofStatus; tier = $tier; requested_model = [string]$sel.CatalogModel; effective_model = $effective; observed_model = $observed; parsed_events = $parsedEvents })
        exit 0
    }

    Write-Host 'PROOF_ETAPA4=PROOF_ABSENT:no-model-field'
    Write-Etapa4Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = $stamp; status = 'PROOF_ABSENT'; reason = 'no-model-field'; tier = $tier; requested_model = [string]$sel.CatalogModel; effective_model = $effective; parsed_events = $parsedEvents; text_echo_ok = ($textOut -match 'pong') })
    exit 0
} catch {
    Write-Host ('PROOF_ETAPA4_ERROR: ' + $_.Exception.Message)
    exit 1
}
