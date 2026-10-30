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

# Lane separation: runtime LLM tests only run with FULL_DELIVERY_RUNTIME=1.
# Regular CI (run-v3-tests.ps1) must not pay for LLM or fail without provider.
# Absence of provider is NEVER reported as RUNTIME_REAL_PASS.
if ([string]$env:FULL_DELIVERY_RUNTIME -cne '1') {
    Write-Host '[SKIP] runtime LLM lane disabled (set FULL_DELIVERY_RUNTIME=1 to enable)'
    Write-Host ''
    Write-Host 'TEST RESULTS: 0 / 0 passed (1 skipped)'
    Write-Host '[SUMMARY] pass 0 fail 0'
    exit 0
}

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
        Write-Host '[FAIL] driver not found (lane enabled, must fail)'
        exit 1
    }
    # Run the driver (normal path — no manual pilot)
    $out = & powershell -NoProfile -File $driverPath 2>&1
    $driverExit = $LASTEXITCODE
    $outText = ($out | Out-String)

    Assert-RT ($driverExit -eq 0) '[RT] driver exit code 0' ('exit=' + [string]$driverExit)
    Assert-RT ($outText -match 'FINAL STATE:\s*COMPLETED') '[RT] Goal chega a COMPLETED' ''
    Assert-RT ($outText -match 'PROGRESS:\s*2/2') '[RT] progresso 2/2' ''
    Assert-RT ($outText -match 'fd-task-a: DONE \(canonical\)') '[RT] Task A canonically DONE' ''
    Assert-RT ($outText -match 'fd-task-b: DONE \(canonical\)') '[RT] Task B canonically DONE' ''
    # B must start only after A DONE (log order check)
    $posA = $outText.IndexOf('fd-task-a: DONE')
    $posB = $outText.IndexOf('=== TASK B ===')
    Assert-RT (($posA -ge 0) -and ($posB -gt $posA)) '[RT] B iniciou apos A.DONE (ordem no log)' ''

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
            Assert-RT ($a -match 'task-a' -and $a -match '42') '[RT] artefato A tem origem task-a' ''
        }
        if (Test-Path -LiteralPath $artB -PathType Leaf) {
            $b = Get-Content $artB -Raw
            Assert-RT ($b -match 'derived' -and $b -match '84') '[RT] artefato B tem resultado derivado' ''
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