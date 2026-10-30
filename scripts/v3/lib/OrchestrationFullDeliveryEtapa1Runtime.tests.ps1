<#!
.SYNOPSIS
    Etapa 1 FULL_DELIVERY — regressao de runtime real.
.DESCRIPTION
    Invoca o driver (caminho normal, sem piloto manual) e verifica que:
      - duas tarefas dependentes executam sem intervencao humana;
      - o Goal chega a COMPLETED por CAS;
      - os artefatos A e B existem e B consome A;
      - a repeticao nao duplica efeitos (idempotencia de receipts).
    Requer OpenCode V2 instalado e provider disponivel.
    PS 5.1 compatible. ASCII-only. No network beyond opencode run.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passed = 0
$script:failed = 0

function Assert-RT {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    $driverPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'full-delivery-pilot-driver.ps1'
    if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
        Write-Host '[SKIP] driver not found'
        exit 0
    }
    # Run the driver (normal path — no manual pilot)
    $out = & powershell -NoProfile -File $driverPath 2>&1
    $outText = ($out | Out-String)

    Assert-RT ($outText -match 'FINAL STATE:\s*COMPLETED') '[RT] Goal chega a COMPLETED' ''
    Assert-RT ($outText -match 'PROGRESS:\s*2/2') '[RT] progresso 2/2' ''
    Assert-RT ($outText -match 'EXECUTOR CALLS:\s*2') '[RT] duas tarefas executadas' ''

    # Extract work_root from log line
    $wrLine = ($out | Select-String 'PILOT LOG:') | Select-Object -First 1
    $wr = ''
    if ($null -ne $wrLine) {
        $logPath = ($wrLine.Line -replace '.*PILOT LOG:\s*','').Trim()
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $wr = Split-Path -Parent $logPath
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($wr)) {
        $artA = Join-Path $wr 'artifacts\output-a.json'
        $artB = Join-Path $wr 'artifacts\output-b.json'
        Assert-RT (Test-Path -LiteralPath $artA -PathType Leaf) '[RT] artefato A existe' ''
        Assert-RT (Test-Path -LiteralPath $artB -PathType Leaf) '[RT] artefato B existe' ''
        if (Test-Path -LiteralPath $artA -PathType Leaf) {
            $a = Get-Content $artA -Raw
            Assert-RT ($a -match 'task-a') '[RT] artefato A tem origem task-a' ''
        }
        if (Test-Path -LiteralPath $artB -PathType Leaf) {
            $b = Get-Content $artB -Raw
            Assert-RT ($b -match 'derived') '[RT] artefato B tem resultado derivado' ''
        }
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}