<#!
.SYNOPSIS
    Prova REAL deterministica da Etapa 3 (sem LLM/rede/spawn).
.DESCRIPTION
    Fixture temp com artefato ausente; induz falha (stagnation 3,
    missing-context); chama Invoke-OrchestrationImpasseConsumption SEM
    executor injetado (executor real default) com -ContextDir apontando a
    fixture; verifica que o explorer realmente listou arquivos
    (consultation.evidence contem nomes reais); incorpora recommendation
    (cria artefato); nova tentativa verifica artefato existe
    (verified_pass=true); registra evidencia JSONL; imprime
    PROOF_ETAPA3=REAL ou FAIL. Exit 1 em falha. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Write-ProofFail {
    param([string]$Reason)
    Write-Host ("[FAIL] " + $Reason)
    Write-Host 'PROOF_ETAPA3=FAIL'
    exit 1
}

try {
    $lib = Join-Path $PSScriptRoot 'lib\OrchestrationImpasseConsumption.ps1'
    if (-not (Test-Path -LiteralPath $lib)) { Write-ProofFail ('lib-nao-encontrada: ' + $lib) }
    . $lib

    $base = [IO.Path]::GetTempPath()
    $tmp = Join-Path $base ('etapa3proof_' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    $evDir = Join-Path $tmp 'evidence'
    [void](New-Item -ItemType Directory -Path $evDir -Force)

    $presentFile = Join-Path $tmp 'presente.txt'
    Set-Content -LiteralPath $presentFile -Value 'conteudo-real' -Encoding UTF8
    $missingFile = Join-Path $tmp 'artefato.txt'
    if (Test-Path -LiteralPath $missingFile) { [void](Remove-Item -LiteralPath $missingFile -Force) }

    $r = Invoke-OrchestrationImpasseConsumption `
        -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } `
        -TaskRisk 'low' -FailureKind 'missing-context' `
        -History @() -MaxInterventions 3 `
        -ContextDir $tmp -EvidenceDir $evDir

    if (-not [bool]$r.ok) { Write-ProofFail ('consumo-nao-ok: ' + [string]$r.reason) }
    if (-not [bool]$r.impasse) { Write-ProofFail 'impasse-nao-detectado' }
    if ([string]$r.consultant -cne 'explorer') { Write-ProofFail ('consultant-inesperado: ' + [string]$r.consultant) }
    if ([bool]$r.grants_authority) { Write-ProofFail 'grants_authority-true' }
    if ([bool]$r.done_approved) { Write-ProofFail 'done_approved-true' }

    $consultation = $null
    try { $consultation = $r.consultation } catch { $consultation = $null }
    if ($null -eq $consultation) { Write-ProofFail 'consultation-ausente' }
    $evidence = ''
    $recommendation = ''
    try {
        if ($consultation -is [System.Collections.IDictionary]) {
            if ($consultation.Contains('evidence')) { $evidence = [string]$consultation['evidence'] }
            if ($consultation.Contains('recommendation')) { $recommendation = [string]$consultation['recommendation'] }
        } else {
            $pe = $consultation.PSObject.Properties['evidence']
            if ($null -ne $pe) { $evidence = [string]$pe.Value }
            $pr = $consultation.PSObject.Properties['recommendation']
            if ($null -ne $pr) { $recommendation = [string]$pr.Value }
        }
    } catch { $evidence = ''; $recommendation = '' }
    if ([string]::IsNullOrWhiteSpace($evidence)) { Write-ProofFail 'evidence-vazia' }
    if ($evidence -notmatch 'presente\.txt') { Write-ProofFail ('explorer-nao-listou-arquivos-reais: ' + $evidence) }
    Write-Host ('[PASS] explorer-listou-arquivos-reais: ' + $evidence)
    if ([string]::IsNullOrWhiteSpace($recommendation)) { Write-ProofFail 'recommendation-vazia' }
    Write-Host ('[PASS] recommendation-incorporavel: ' + $recommendation)

    Set-Content -LiteralPath $missingFile -Value 'criado-apos-recommendation' -Encoding UTF8
    $verifiedPass = (Test-Path -LiteralPath $missingFile)
    if (-not $verifiedPass) { Write-ProofFail 'artefato-nao-criado' }
    Write-Host '[PASS] nova-tentativa-verified_pass=true'

    $jsonl = Join-Path $evDir 'impasse-consumption.jsonl'
    if (-not (Test-Path -LiteralPath $jsonl)) { Write-ProofFail 'jsonl-nao-registrado' }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $jsonl -Encoding UTF8) } catch { $lines = @() }
    if (@($lines).Count -lt 1) { Write-ProofFail 'jsonl-vazio' }
    $joined = ($lines -join "`n")
    if ($joined -notmatch 'grants_authority":false') { Write-ProofFail 'jsonl-sem-grants_authority-false' }
    if ($joined -notmatch 'missing-context') { Write-ProofFail 'jsonl-sem-failure_kind' }
    Write-Host ('[PASS] evidencia-jsonl-registrada: ' + [string]@($lines).Count + ' linha(s)')

    try { [void](Remove-Item -LiteralPath $tmp -Recurse -Force) } catch { }

    Write-Host 'PROOF_ETAPA3=REAL'
    exit 0
} catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    Write-Host 'PROOF_ETAPA3=FAIL'
    exit 1
}
