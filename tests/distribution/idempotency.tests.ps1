# idempotency.tests.ps1 — run1 == run2 ignorando backups/manifest timestamps.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
function Get-StateRows([string]$Dir, [string]$Prefix) {
  # relativos compostos SOMENTE por Name (sem Substring de FullName) —
  # mesmo padrao do installer; robusto a TEMP em forma curta 8.3.
  $rows = New-Object System.Collections.ArrayList
  foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
    $rel = if ($Prefix) { $Prefix + '\' + $item.Name } else { $item.Name }
    if ($item.PSIsContainer) {
      if ($item.Name -in @('backups', 'node_modules')) { continue }
      foreach ($r in (Get-StateRows $item.FullName $rel)) { [void]$rows.Add($r) }
    }
    else {
      $h = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
      [void]$rows.Add($rel + '=' + $h)
    }
  }
  return $rows
}
function Get-StateKey([string]$OcDir) {
  return (((Get-StateRows $OcDir '') | Sort-Object) -join "`n")
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
  $out2 = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome *>&1 | Out-String
  $c2 = $LASTEXITCODE
  Assert ($c2 -eq 0) 'run2 exit 0'
  $s2 = Get-StateKey $ocDir
  Assert ($s1 -eq $s2) 'estado identico entre run1 e run2 (exceto backups/manifest timestamps)'
  # P9.1: idempotencia VISIVEL no plano — toda skill gerenciada deve SKIP.
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    Assert ($out2 -match ('\[SKIP\] skills/' + $s + '/ \(inalterado\)')) ('run2 [SKIP] skills/' + $s + '/')
  }
  Assert ($out2 -notmatch '\[UPDATE\] skills/') 'run2 sem [UPDATE] de skills'
  Assert ($out2 -notmatch '\[CREATE\]') 'run2 sem nenhum [CREATE]'
  Assert ($out2 -notmatch '\[UPDATE\] AGENTS\.md') 'run2 AGENTS.md SKIP'
  Assert ($out2 -notmatch '\[UPDATE\] agents/') 'run2 agents SKIP'
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
