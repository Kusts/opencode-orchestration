# eol-checkout.tests.ps1 — regressao CRLF: repo com CRLF instala com exit 0.
# Simula checkout Windows com core.autocrlf=true: copia o repo para temp,
# converte *.md/*.ps1/*.ts/*.tmpl/*.jsonc da copia para CRLF (binario,
# sem duplicar CRs) e roda o install.ps1 DA COPIA. PS 5.1 compativel.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
function Has-CR([string]$Path) {
  $b = [IO.File]::ReadAllBytes($Path)
  foreach ($by in $b) { if ($by -eq 13) { return $true } }
  return $false
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpCopy = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-eol-repo-' + [guid]::NewGuid().ToString('N'))
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-eol-home-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpCopy -Force | Out-Null
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  foreach ($e in @(Get-ChildItem -LiteralPath $RepoRoot -Force)) {
    if ($e.Name -ceq '.git') { continue }
    $dst = Join-Path $TmpCopy $e.Name
    if ($e.PSIsContainer) {
      Copy-Item -LiteralPath $e.FullName -Destination $dst -Recurse -Force
    }
    else {
      Copy-Item -LiteralPath $e.FullName -Destination $dst -Force
    }
  }
  Assert (Test-Path -LiteralPath (Join-Path $TmpCopy 'install.ps1') -PathType Leaf) 'copia do repo contem install.ps1'
  $exts = @('.md', '.ps1', '.ts', '.tmpl', '.jsonc')
  $converted = 0
  foreach ($f in @(Get-ChildItem -File -LiteralPath $TmpCopy -Recurse -ErrorAction SilentlyContinue)) {
    if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $out = New-Object System.Collections.Generic.List[byte]
    $prev = -1
    $touched = $false
    foreach ($by in $b) {
      if (($by -eq 10) -and ($prev -ne 13)) { $out.Add(13); $touched = $true }
      $out.Add($by)
      $prev = $by
    }
    if ($touched) {
      [IO.File]::WriteAllBytes($f.FullName, $out.ToArray())
      $converted += 1
    }
  }
  Assert ($converted -gt 0) ('arquivos convertidos p/ CRLF: ' + $converted)
  $probe = Join-Path $TmpCopy 'install.ps1'
  Assert (Has-CR $probe) 'install.ps1 da copia esta em CRLF (bug exercitavel)'
  if (-not (Test-Path -LiteralPath (Join-Path $TmpCopy 'models.jsonc') -PathType Leaf)) {
    Copy-Item -LiteralPath (Join-Path $TmpCopy 'models.example.jsonc') -Destination (Join-Path $TmpCopy 'models.jsonc') -Force
  }
  New-Item -ItemType Directory -Path (Join-Path $TmpHome '.config\opencode\node_modules\@opencode-ai\plugin') -Force | Out-Null
  $out = & (Join-Path $TmpCopy 'install.ps1') -TargetHome $TmpHome 2>&1 | Out-String
  $code = $LASTEXITCODE
  Assert ($code -eq 0) ('install da copia CRLF exit 0 (obteve ' + $code + ')')
  Assert ($out -notmatch 'pos-hash divergente') 'sem erro pos-hash divergente'
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $agentsMd = Join-Path $ocDir 'AGENTS.md'
  Assert (Test-Path -LiteralPath $agentsMd -PathType Leaf) 'AGENTS.md criado'
  if (Test-Path -LiteralPath $agentsMd -PathType Leaf) {
    $t = [IO.File]::ReadAllText($agentsMd, [Text.Encoding]::UTF8)
    Assert (([regex]::Matches($t, '<!-- opencode-orchestration:start -->')).Count -eq 1) 'AGENTS.md 1 marker start'
    Assert (([regex]::Matches($t, '<!-- opencode-orchestration:end -->')).Count -eq 1) 'AGENTS.md 1 marker end'
    Assert (-not (Has-CR $agentsMd)) 'AGENTS.md instalado em LF'
  }
  $agentFiles = @(Get-ChildItem -File (Join-Path $ocDir 'agents\*.md') -ErrorAction SilentlyContinue)
  Assert ($agentFiles.Count -eq 19) ('19 agents instalados (achado ' + $agentFiles.Count + ')')
  $lfBad = New-Object System.Collections.ArrayList
  # Config: arquivo real detectado (opencode.jsonc vence se ambos existirem;
  # fresh install cria opencode.json).
  $configProbe = Join-Path $ocDir 'opencode.json'
  if (Test-Path -LiteralPath (Join-Path $ocDir 'opencode.jsonc') -PathType Leaf) { $configProbe = Join-Path $ocDir 'opencode.jsonc' }
  foreach ($p in @(
    $configProbe,
    (Join-Path $ocDir 'plugins\orchestration-enforcement.ts'),
    (Join-Path $ocDir 'skills\hybrid-development\SKILL.md')
  )) {
    if ((Test-Path -LiteralPath $p -PathType Leaf) -and (Has-CR $p)) { [void]$lfBad.Add($p) }
  }
  foreach ($af in $agentFiles) {
    if (Has-CR $af.FullName) { [void]$lfBad.Add($af.FullName); break }
  }
  Assert ($lfBad.Count -eq 0) 'instalados em LF (json, plugin, skill, agents)'
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $TmpCopy) { Remove-Item -LiteralPath $TmpCopy -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
