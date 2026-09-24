# package-consistency.tests.ps1 — wrapper: falha se o checker 6.3 exit != 0.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$checker = Join-Path $RepoRoot 'scripts\test-package-consistency.ps1'
Assert (Test-Path -LiteralPath $checker -PathType Leaf) 'checker scripts\test-package-consistency.ps1 existe'
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $checker 2>&1 | Out-String
$code = $LASTEXITCODE
Write-Host $out
Assert ($code -eq 0) 'checker exit 0 (pacote consistente)'
Assert (($out -notmatch '\[FAIL\]')) 'nenhum [FAIL] no checker'
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
