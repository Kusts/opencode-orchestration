# plugin-enforcement.tests.ps1 — P3: mandates distintos planner/worker/neutral + coalescencia + idempotencia.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Harness = Join-Path $PSScriptRoot 'plugin-harness'
Assert ((Test-Path -LiteralPath (Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts'))) 'plugin fonte existe'
Assert ((Test-Path -LiteralPath (Join-Path $Harness 'run.ts'))) 'harness run.ts existe'
$bunCmd = Get-Command bun -ErrorAction SilentlyContinue
if ($null -eq $bunCmd) {
  # Gate obrigatorio: CI provisiona bun via npm em ambos os jobs; sem bun
  # nao ha como rodar o harness, e isso e falha - nunca skip.
  Assert ($false) 'bun disponivel (gate obrigatorio: CI provisiona bun)'
  Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
  exit 1
}
$out = & bun (Join-Path $Harness 'run.ts') 2>&1
$code = $LASTEXITCODE
Write-Host ($out -join "`n")
Assert ($code -eq 0) 'bun harness exit 0'
$notOk = @($out | Where-Object { $_ -match 'NOT OK' }).Count
Assert ($notOk -eq 0) 'nenhum NOT OK no harness'
$summary = @($out | Where-Object { $_ -match '^SUMMARY' })
Assert (($summary.Count -gt 0) -and ($summary[0] -match 'fail=0')) 'summary fail=0'
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
