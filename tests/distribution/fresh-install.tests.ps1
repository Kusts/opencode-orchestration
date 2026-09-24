# fresh-install.tests.ps1 — instalacao limpa em home temporario.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-fresh-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  New-Item -ItemType Directory -Path (Join-Path $TmpHome '.config\opencode\node_modules\@opencode-ai\plugin') -Force | Out-Null
  $out = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  $code = $LASTEXITCODE
  Assert ($code -eq 0) 'install exit 0'
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $agentsMd = Join-Path $ocDir 'AGENTS.md'
  Assert (Test-Path -LiteralPath $agentsMd -PathType Leaf) 'AGENTS.md criado'
  if (Test-Path -LiteralPath $agentsMd -PathType Leaf) {
    $t = [IO.File]::ReadAllText($agentsMd, [Text.Encoding]::UTF8)
    Assert (([regex]::Matches($t, '<!-- opencode-orchestration:start -->')).Count -eq 1) 'AGENTS.md 1 marker start'
    Assert (([regex]::Matches($t, '<!-- opencode-orchestration:end -->')).Count -eq 1) 'AGENTS.md 1 marker end'
    Assert ($t -notmatch '\{\{[^}]+\}\}') 'AGENTS.md sem tokens'
  }
  $agentFiles = @(Get-ChildItem -File (Join-Path $ocDir 'agents\*.md') -ErrorAction SilentlyContinue)
  Assert ($agentFiles.Count -eq 19) ('19 agents instalados (achado ' + $agentFiles.Count + ')')
  $jsonPath = Join-Path $ocDir 'opencode.json'
  Assert (Test-Path -LiteralPath $jsonPath -PathType Leaf) 'opencode.json criado'
  if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
    $j = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    Assert ((@($j.agent.PSObject.Properties.Name).Count) -eq 17) 'opencode.json 17 blocos agent'
    $hasBM = ($null -ne ($j.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))
    Assert (-not $hasBM) 'agent.build sem model'
    $models = (([IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
    Assert ($j.model -eq $models.planner) 'root model = planner'
    Assert ($j.agent.title.model -eq $models.planner) 'title.model = planner'
    Assert ($j.agent.coder.model -eq $models.cheap) 'coder.model = cheap'
    Assert ($j.agent.reviewer.model -eq $models.strong) 'reviewer.model = strong'
  }
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    Assert (Test-Path -LiteralPath (Join-Path $ocDir ('skills\' + $s + '\SKILL.md')) -PathType Leaf) ('skill ' + $s)
  }

  # ---- P9.1: correspondencia estrutural source -> destination ----------------
  # RelativePath correto: a arvore instalada de cada skill deve ser isomorfa
  # a arvore da fonte (skills-core), sem fragmentos de sufixo (nt/rs/on/ts)
  # nem arquivos extras — validado estruturalmente, sem hardcode de fragmentos.
  function Get-TreeSet([string]$Dir) {
    $found = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $found.ToArray() }
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force)) {
      if ($item.PSIsContainer) {
        $found.Add(($item.Name + '\'))
        foreach ($c in (Get-TreeSet $item.FullName)) { $found.Add(($item.Name + '\' + $c)) }
      }
      else { $found.Add($item.Name) }
    }
    return $found.ToArray()
  }
  function Get-FileRelSet([string]$Dir) {
    # relativos de arquivos compostos SOMENTE por Name (sem Substring de
    # FullName) — mesmo padrao do installer.
    $found = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $found.ToArray() }
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force)) {
      if ($item.PSIsContainer) {
        foreach ($c in (Get-FileRelSet $item.FullName)) { $found.Add(($item.Name + '\' + $c)) }
      }
      else { $found.Add($item.Name) }
    }
    return $found.ToArray()
  }
  function Get-NormalizedHash([string]$Path) {
    # hash do conteudo com a unica normalizacao que o installer faz (LF)
    $txt = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $norm = ($txt -replace "`r`n", "`n" -replace "`r", "`n")
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($norm)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') } finally { $sha.Dispose() }
  }
  $skillsCore = Join-Path $RepoRoot 'skills-core'
  $skillsDstRoot = Join-Path $ocDir 'skills'
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    $srcSet = @(Get-TreeSet (Join-Path $skillsCore $s) | Sort-Object)
    $dstSet = @(Get-TreeSet (Join-Path $skillsDstRoot $s) | Sort-Object)
    Assert (($srcSet -join '|') -eq ($dstSet -join '|')) ('estrutura skill ' + $s + ' isomorfa a fonte (sem fragmentos/extras): ' + $srcSet.Count + ' entradas')
    $mismatch = New-Object System.Collections.ArrayList
    foreach ($rel in @(Get-FileRelSet (Join-Path $skillsCore $s))) {
      $dp = Join-Path (Join-Path $skillsDstRoot $s) $rel
      $sp = Join-Path (Join-Path $skillsCore $s) $rel
      if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) { [void]$mismatch.Add($rel + ' (ausente)'); continue }
      if ((Get-NormalizedHash $sp) -ne (Get-FileHash -LiteralPath $dp -Algorithm SHA256).Hash) { [void]$mismatch.Add($rel + ' (hash)') }
    }
    Assert ($mismatch.Count -eq 0) ('hash(source normalizado)==hash(dest) skill ' + $s + ($mismatch -join ', '))
  }
  $extraSkillDirs = @(Get-ChildItem -Directory $skillsDstRoot -ErrorAction SilentlyContinue | Where-Object { @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion') -notcontains $_.Name })
  Assert ($extraSkillDirs.Count -eq 0) 'nenhum diretorio inesperado sob skills/ (nenhum fragmento nt/rs/on/ts)'
  $expectedManaged = New-Object System.Collections.ArrayList
  [void]$expectedManaged.Add('AGENTS.md')
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | Sort-Object Name)) { [void]$expectedManaged.Add('agents\' + $f.Name) }
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    foreach ($rel in @(Get-FileRelSet (Join-Path $skillsCore $s))) {
      [void]$expectedManaged.Add('skills\' + $s + '\' + $rel)
    }
  }
  [void]$expectedManaged.Add('plugins\orchestration-enforcement.ts')
  [void]$expectedManaged.Add('opencode.json')
  if (Test-Path -LiteralPath (Join-Path $TmpHome '.opencode-orchestration\manifest.json') -PathType Leaf) {
    $m = ([IO.File]::ReadAllText((Join-Path $TmpHome '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
    $gotManaged = @($m.managed_files | ForEach-Object { ([string]$_.relative) -replace '/', '\' } | Sort-Object)
    $wantManaged = @($expectedManaged | Sort-Object)
    Assert (($gotManaged -join '|') -eq ($wantManaged -join '|')) ('manifest.managed_files == conjunto esperado (' + $wantManaged.Count + ')')
  }

  $plug = Join-Path $ocDir 'plugins\orchestration-enforcement.ts'
  Assert (Test-Path -LiteralPath $plug -PathType Leaf) 'plugin instalado'
  if (Test-Path -LiteralPath $plug -PathType Leaf) {
    Assert ([IO.File]::ReadAllText($plug, [Text.Encoding]::UTF8).Contains('orchestration-enforcement')) 'plugin contem marker'
  }
  $mf = Join-Path $TmpHome '.opencode-orchestration\manifest.json'
  Assert (Test-Path -LiteralPath $mf -PathType Leaf) 'manifest criado'
  if (Test-Path -LiteralPath $mf -PathType Leaf) {
    $m = ([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    Assert ($m.package_version -eq '1.0.0-hardening') 'manifest package_version'
    Assert ($m.plugin_dependency -eq '@opencode-ai/plugin@1.18.31') 'manifest plugin_dependency'
    Assert (-not [string]::IsNullOrWhiteSpace($m.installed_at)) 'manifest installed_at'
    Assert ($m.target_home -eq $TmpHome) 'manifest target_home'
    Assert ((@($m.managed_files).Count) -gt 20) 'manifest managed_files>20'
    $raw = [IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)
    Assert (($raw -notmatch '(?i)secret') -and ($raw -notmatch 'sk-ant-') -and ($raw -notmatch '(?i)password')) 'manifest sem secrets'
  }
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
