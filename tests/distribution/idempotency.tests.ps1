# idempotency.tests.ps1 — run1 == run2 ignorando backups/manifest timestamps.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
function Get-StateKey([string]$OcDir) {
  $rows = New-Object System.Collections.ArrayList
  foreach ($f in @(Get-ChildItem -File (Join-Path $OcDir '*') -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    if ($f.FullName -like '*\backups\*') { continue }
    if ($f.FullName -like '*\node_modules\*') { continue }
    $rel = $f.FullName.Substring($OcDir.Length + 1)
    $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    [void]$rows.Add($rel + '=' + $h)
  }
  return ($rows -join "`n")
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-idem-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  New-Item -ItemType Directory -Path (Join-Path $TmpHome '.config\opencode\node_modules\@opencode-ai\plugin') -Force | Out-Null
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  $c1 = $LASTEXITCODE
  Assert ($c1 -eq 0) 'run1 exit 0'
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $s1 = Get-StateKey $ocDir
  $m1 = ([IO.File]::ReadAllText((Join-Path $TmpHome '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json)
  Start-Sleep -Seconds 2
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  $c2 = $LASTEXITCODE
  Assert ($c2 -eq 0) 'run2 exit 0'
  $s2 = Get-StateKey $ocDir
  Assert ($s1 -eq $s2) 'estado identico entre run1 e run2 (exceto backups/manifest timestamps)'
  $m2 = ([IO.File]::ReadAllText((Join-Path $TmpHome '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json)
  $m1copy = ($m1 | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
  $m2copy = ($m2 | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
  $m1copy.installed_at = 'X'
  $m2copy.installed_at = 'X'
  Assert ((($m1copy | ConvertTo-Json -Depth 32)) -eq (($m2copy | ConvertTo-Json -Depth 32))) 'manifest estavel (exceto installed_at)'
  $t = [IO.File]::ReadAllText((Join-Path $ocDir 'AGENTS.md'), [Text.Encoding]::UTF8)
  Assert (([regex]::Matches($t, '<!-- opencode-orchestration:start -->')).Count -eq 1) 'sem duplicacao de bloco apos 2 runs'
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
